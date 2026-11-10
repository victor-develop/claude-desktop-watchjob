#!/usr/bin/env node
// Slack 的 WebSocket 事件缓冲 daemon:一条连接收下整个工作区的消息,写成本地事件文件,
// 让各个 probe 从文件里读,而不是每轮各自去打 Slack 接口。
//
// 为什么是「缓冲 + 瘦 probe」而不是「probe 直接连 WS」:probe 每轮是一个新进程,建连接
// 要换令牌、等 hello,比轮询还贵。WS 的价值在于**一条连接服务所有 watch**,所以连接必须
// 是常驻的,probe 退化成读文件。
//
// 它不替代轮询,只是让轮询变少:
//   - 网页版的 WS 断线不重发,所以缓冲只敢声称「从某个时刻起是全的」(status.json 的
//     covered_from),游标比它早的 probe 这一轮照样走轮询补齐。
//   - WS 只推**你是成员的**会话,而轮询用 user token 读得到没加入的公共频道。所以 daemon
//     会把「我是成员的会话」列成 channels.json,probe 只对名单里的频道信缓冲(见下)。
//   - probe 还会按 SLACK_WS_VERIFY 的节奏定期轮询校验一次,防止某个频道的帧根本没推过来
//     这种**静默失效**(这套机制里最怕的一类失败)。
//
// 凭据:跟 slackcli 用的是同一套(浏览器会话)。顺序:
//   1. 环境变量 SLACK_WS_COOKIE_D / SLACK_WS_TOKEN / SLACK_WS_WORKSPACE
//   2. slackcli 的 ~/.config/slackcli/workspaces.json(xoxd_token = d cookie,xoxc_token = 令牌)
// 令牌和 cookie 只在内存里传给 SDK,不进日志、不进事件文件、不进 status.json。
//
// 依赖:gabriel-slack(MIT,https://github.com/Easy-Ez/gabriel-slack,锁死 0.1.1)。
// 选这个版本是因为它被人工审计过:tarball 哈希与 SLSA 来源证明一致、从对应 tag 重新编译出的
// JS 逐字节相同、没有安装脚本、只连 Slack 的主机。审计不是本仓库做的,**升级要重新审一遍**。
// 审计发现的两个问题这里按同样办法补上:
//   1. 服务器给的重连地址没有检查主机,而连接带着 cookie → createWebSocket 只放行 wss:// + Slack 主机
//   2. SDK 自带的脱敏会留令牌前缀 → 这里用 silentLogger,自己的日志一律不碰凭据
//
// 用法:
//   npm install --prefix ~/.claude/skills/incremental-watch --omit=dev
//   node scripts/slack-ws-daemon.mjs            # 前台跑(调试)
//   nohup node scripts/slack-ws-daemon.mjs >/dev/null 2>&1 & disown   # 常驻
//   node scripts/slack-ws-daemon.mjs --smoke 20 # 连 20 秒,打一行统计就退出(不写缓冲)
//
// 参数:
//   --state-dir DIR    默认 ~/.claude/watch/_slack-ws
//   --retain-hours N   事件保留多久,默认 48
//   --smoke SECONDS    冒烟:连上跑若干秒,只打统计(条数、频道数),不打正文
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// ---------- 参数 ----------
const argv = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && argv[i + 1] !== undefined ? argv[i + 1] : dflt;
};
const STATE_DIR = opt("state-dir", path.join(os.homedir(), ".claude", "watch", "_slack-ws"));
// 事件文件里是**整个工作区**的消息正文,比轮询那条路(只有被盯频道)暴露面大得多。
// 目录 0700、文件 0600,别用默认权限。
const DIR_MODE = 0o700, FILE_MODE = 0o600;
const RETAIN_HOURS = Number(opt("retain-hours", process.env.SLACK_WS_RETAIN_HOURS ?? 48));
const SMOKE = argv.includes("--smoke") ? Number(opt("smoke", 20)) : 0;

const EVENTS = path.join(STATE_DIR, "events.jsonl");
const CHANNELS = path.join(STATE_DIR, "channels.json");
const STATUS = path.join(STATE_DIR, "status.json");
const USERS = path.join(STATE_DIR, "users.json");
const LOCK = path.join(STATE_DIR, "lock");
const LOG = path.join(STATE_DIR, "log");

// Slack ts 和本地时间同一个刻度(秒),这样 covered_from 能直接跟游标比。
// 但两个时钟不是同一个:covered_from 用本机时间算,游标是 Slack 服务端的 ts。
// 本机慢 Δ 秒时 covered_from 会比真实的覆盖起点早 Δ —— 游标落在这段里的 probe 会通过闸门,
// 而那段消息 daemon 还没连上、缓冲里根本没有,读出空数组之后游标照样前进,**永久丢掉**。
// 所以 covered_from 一律往后推 SKEW_MARGIN 秒。推晚只会让更多轮退回轮询(贵一点),
// 推早才会丢消息,方向必须偏保守。
const SKEW_MARGIN = Number(process.env.SLACK_WS_SKEW_MARGIN ?? 120);
const nowTs = () => (Date.now() / 1000).toFixed(6);
const coverageTs = () => (Date.now() / 1000 + SKEW_MARGIN).toFixed(6);
const log = (line) => {
  const text = `[${new Date().toISOString()}] ${line}\n`;
  try { fs.appendFileSync(LOG, text, { mode: FILE_MODE }); } catch { /* 日志写不了不该让 daemon 死 */ }
  if (SMOKE || process.env.SLACK_WS_FOREGROUND === "1") process.stderr.write(text);
};

// ---------- 凭据 ----------
// 读进来就只往 SDK 里传。任何分支都不要把它放进 log / status / events。
function credentials() {
  const fromEnv = {
    cookieD: process.env.SLACK_WS_COOKIE_D || "",
    token: process.env.SLACK_WS_TOKEN || "",
    workspace: process.env.SLACK_WS_WORKSPACE || "",
  };
  if (fromEnv.cookieD) return fromEnv;
  const file = process.env.SLACKCLI_CONFIG
    || path.join(os.homedir(), ".config", "slackcli", "workspaces.json");
  let conf;
  try { conf = JSON.parse(fs.readFileSync(file, "utf8")); }
  catch (err) {
    throw new Error(`读不到 slackcli 的凭据(${file}):${err.message}。`
      + `先跑一次 slackcli auth list 确认已登录,或者自己给 SLACK_WS_COOKIE_D`);
  }
  const id = fromEnv.workspace || conf.default_workspace;
  const ws = conf.workspaces?.[id] || Object.values(conf.workspaces || {})[0];
  if (!ws?.xoxd_token) {
    throw new Error("slackcli 的凭据里没有 xoxd_token(浏览器会话)。"
      + "`slackcli auth list` 显示 Auth: 🌐 Browser 时才有");
  }
  return { cookieD: ws.xoxd_token, token: ws.xoxc_token || "", workspace: ws.workspace_id || id || "" };
}

// ---------- 单实例锁 ----------
function takeLock() {
  fs.mkdirSync(STATE_DIR, { recursive: true, mode: DIR_MODE });
  try {
    fs.mkdirSync(LOCK);
  } catch {
    // pid 文件读不到或者坏掉时**不抢锁**:两个 daemon 同时跑的话,一个的 trim(读→改→rename)
    // 会把另一个在这期间 append 的行整段丢掉。宁可要人手动清一下。
    let pid = NaN;
    try { pid = Number(fs.readFileSync(path.join(LOCK, "pid"), "utf8").trim()); } catch { /* 下面按坏锁处理 */ }
    if (!Number.isInteger(pid) || pid <= 0) {
      process.stderr.write(`锁目录 ${LOCK} 在,但 pid 文件读不出来。确认没有 daemon 在跑之后手动删掉它再启动\n`);
      process.exit(1);
    }
    let alive = false;
    try { process.kill(pid, 0); alive = true; } catch { alive = false; }
    if (alive) {
      process.stderr.write(`已经有一个 daemon 在跑(pid=${pid}),这次不启动\n`);
      process.exit(1);
    }
    log(`接管过期的锁(旧 pid=${pid} 已经没了)`);
  }
  fs.writeFileSync(path.join(LOCK, "pid"), String(process.pid));
  const drop = () => { try { fs.rmSync(LOCK, { recursive: true, force: true }); } catch { /* 退出路径,尽力而为 */ } };
  process.on("exit", drop);
  for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => { drop(); process.exit(0); });
}

// ---------- 状态 ----------
// covered_from = 缓冲「从这个 ts 起是全的」。游标早于它的 probe 必须自己轮询补齐。
// 取两者较晚的:连上的时刻(断线期间丢的帧补不回来)、保留窗口里最旧的事件(被裁掉的也没了)。
const state = { connectedFrom: null, retainFloor: null, wsState: "STARTING", epoch: 0, lastFrameAt: null, frames: 0 };
const coveredFrom = () => {
  const xs = [state.connectedFrom, state.retainFloor].filter(Boolean);
  return xs.length ? xs.reduce((a, b) => (a > b ? a : b)) : null;
};
function writeStatus() {
  if (SMOKE) return;   // 冒烟不写状态:写成 READY 却一条事件都不落盘,会让 probe 静默读空
  const payload = {
    pid: process.pid,
    state: state.wsState,
    epoch: state.epoch,
    covered_from: coveredFrom(),
    connected_from: state.connectedFrom,
    retain_floor: state.retainFloor,
    last_frame_at: state.lastFrameAt,
    frames: state.frames,
    updated_at: nowTs(),
  };
  const tmp = `${STATUS}.${process.pid}`;
  try { fs.writeFileSync(tmp, `${JSON.stringify(payload)}\n`, { mode: FILE_MODE }); fs.renameSync(tmp, STATUS); }
  catch { try { fs.rmSync(tmp, { force: true }); } catch { /* 下一轮心跳再写 */ } }
}

// ---------- 成员名单 ----------
// 这是 WS 和轮询最大的一处能力差:轮询用 user token 打 conversations.history,没加入的公共
// 频道照样读得到;WS 只推**你是成员的**会话。不比对的话,盯一个没加入的频道就是
// 「daemon 一切正常 + 一条都收不到」,probe 每轮报「没有新消息」—— 正是最怕的静默失效。
// 所以把成员名单落盘,probe 只对名单里的频道信缓冲;名单拿不到就整个不写,probe 一律轮询。
async function refreshChannels(core) {
  const ids = [];
  let cursor = "";
  try {
    for (let page = 0; page < 20; page += 1) {
      const res = await core.callWebApi("users.conversations", {
        types: "public_channel,private_channel,mpim,im",
        exclude_archived: true, limit: 1000, ...(cursor ? { cursor } : {}),
      });
      for (const c of res?.channels || []) if (c?.id) ids.push(c.id);
      cursor = res?.response_metadata?.next_cursor || "";
      if (!cursor) break;
    }
  } catch (err) {
    log(`取成员名单失败:${err.message}(名单不更新,probe 会对这些频道走轮询)`);
    return;
  }
  if (!ids.length) { log("成员名单是空的,不写 —— 宁可让 probe 走轮询"); return; }
  const tmp = `${CHANNELS}.${process.pid}`;
  try {
    fs.writeFileSync(tmp, `${JSON.stringify({ updated_at: nowTs(), ids })}\n`, { mode: FILE_MODE });
    fs.renameSync(tmp, CHANNELS);
    log(`成员名单 ${ids.length} 个会话`);
  } catch (err) {
    try { fs.rmSync(tmp, { force: true }); } catch { /* 下一轮再写 */ }
    log(`写成员名单失败:${err.message}`);
  }
}

// ---------- 用户名缓存 ----------
// 事件里只有 user id;名字异步补,probe 读 users.json 做映射,查不到就退回 id。
const users = new Map();
try { for (const [k, v] of Object.entries(JSON.parse(fs.readFileSync(USERS, "utf8")))) users.set(k, v); } catch { /* 没有就是空的 */ }
let usersDirty = false;
const pendingUsers = new Set();
function flushUsers() {
  if (!usersDirty) return;
  usersDirty = false;
  const tmp = `${USERS}.${process.pid}`;
  try { fs.writeFileSync(tmp, `${JSON.stringify(Object.fromEntries(users))}\n`, { mode: FILE_MODE }); fs.renameSync(tmp, USERS); }
  catch { try { fs.rmSync(tmp, { force: true }); } catch { /* 下一轮再写 */ } }
}
async function resolveUser(core, id) {
  if (!id || users.has(id) || pendingUsers.has(id)) return;
  pendingUsers.add(id);
  try {
    const res = await core.callWebApi("users.info", { user: id });
    const u = res?.user;
    if (u) { users.set(id, u.profile?.real_name || u.real_name || u.name || id); usersDirty = true; }
  } catch (err) {
    log(`查用户名失败(${id}):${err.message}`);
  } finally {
    pendingUsers.delete(id);
  }
}

// ---------- 事件 ----------
// 只收人发的普通消息,子类型白名单跟轮询那条路一模一样(probe-slack.sh 的 NORMALIZE_JQ):
// 空 / thread_broadcast / file_share。编辑、删除、join/leave 这些不进缓冲。
// **不**在这里按 SELF / agent 前缀过滤:那是每个 watch 自己的配置,留给 probe。
const KEEP_SUBTYPES = new Set(["", "thread_broadcast", "file_share"]);
function record(frame) {
  const subtype = frame.subtype ?? "";
  if (!KEEP_SUBTYPES.has(subtype)) return null;
  if (!frame.channel || !frame.ts) return null;
  const root = frame.thread_ts ?? frame.ts;
  return {
    ch: frame.channel,
    ts: frame.ts,
    thread_ts: root === frame.ts ? null : root,
    user: frame.user ?? null,
    bot_id: frame.bot_id ?? null,
    subtype,
    // 正文截一刀再存:probe 自己还会按 BODY_MAX 截,这里只是给事件文件一个大小上界
    text: typeof frame.text === "string" ? frame.text.slice(0, 4000) : "",
    recv: nowTs(),
  };
}

// ---------- 保留窗口 ----------
function trim() {
  if (!Number.isFinite(RETAIN_HOURS) || RETAIN_HOURS <= 0) return;
  let lines;
  try { lines = fs.readFileSync(EVENTS, "utf8").split("\n").filter(Boolean); }
  catch { return; }
  const floor = Date.now() / 1000 - RETAIN_HOURS * 3600;
  const kept = lines.filter((l) => {
    const ts = Number(l.slice(0, 200).match(/"ts":"([0-9.]+)"/)?.[1] ?? 0);
    return ts >= floor;
  });
  if (kept.length === lines.length) return;
  const tmp = `${EVENTS}.${process.pid}`;
  try {
    fs.writeFileSync(tmp, kept.length ? `${kept.join("\n")}\n` : "", { mode: FILE_MODE });
    fs.renameSync(tmp, EVENTS);
    // 裁掉了旧事件 → 缓冲的覆盖下界抬到现在最旧的那条
    const oldest = kept.length ? JSON.parse(kept[0]).ts : nowTs();
    state.retainFloor = oldest;
    log(`裁掉 ${lines.length - kept.length} 条旧事件,覆盖下界抬到 ${oldest}`);
  } catch (err) {
    try { fs.rmSync(tmp, { force: true }); } catch { /* 下一轮再裁 */ }
    log(`裁剪事件文件失败:${err.message}`);
  }
}

// ---------- 连接 ----------
// 带着 cookie 的连接只许发往 Slack 自己的主机。SDK 会用服务器给的 reconnect_url 重连,
// 那个地址来自网络,不检查主机就等于把会话 cookie 交给任意一台服务器。
// 只有 slack.com 开 WS;-edge / -files 是 CDN 和文件域,放进来只是无谓放宽
const SLACK_HOST = /(^|\.)slack\.com$/i;
function socketUrlAllowed(url) {
  try {
    const u = new URL(url);
    return u.protocol === "wss:" && SLACK_HOST.test(u.hostname) && !u.username && !u.password;
  } catch { return false; }
}

async function main() {
  const creds = credentials();
  // 冒烟只连不写:不拿锁、不写状态、不写事件,跟正在跑的 daemon 互不干扰
  if (!SMOKE) { takeLock(); fs.mkdirSync(STATE_DIR, { recursive: true, mode: DIR_MODE }); }

  const { GabrielCore, silentLogger } = await import("gabriel-slack");
  const { default: WebSocket } = await import("ws");

  const core = new GabrielCore({
    auth: { cookieD: creds.cookieD, token: creds.token || undefined, workspace: creds.workspace || undefined },
    logger: silentLogger,
    createWebSocket: (url, headers) => {
      if (!socketUrlAllowed(url)) throw new Error("拒绝连接:WebSocket 地址不是 Slack 的主机");
      return new WebSocket(url, { headers });
    },
  });

  const seen = new Set();   // 同一帧可能重复到达(重连后的补发):按 频道:ts 去重
  const smokeChannels = new Set();
  let smokeCount = 0;

  core.onHello((info) => {
    state.epoch = info.epoch ?? state.epoch + 1;
    // 每次 hello 都把覆盖下界推到现在:断开期间的帧网页版不补发,不能假装收到过。
    // fast reconnect 也一样 —— Slack 没有承诺重放,宁可多轮询一轮。
    state.connectedFrom = coverageTs();
    // 用 Core 的话要自己报「补拉做完了」,否则 SDK 一直停在 RESYNCING。
    // 这里的「补拉」是交给 probe 做的(游标早于 covered_from 就轮询一轮),所以连上即就位。
    // 失败不能吞:SDK 会停在 RESYNCING,5 秒后心跳把状态覆写回去,probe 从此永远走轮询 ——
    // 方向是安全的,但 WS 模式静默失效、没有任何线索,所以至少要留一行
    try { core.ws.markReady(false, state.epoch); }
    catch (err) { log(`markReady 失败(${err.message}),状态会停在 RESYNCING,probe 将一直走轮询`); }
    state.wsState = "READY";
    writeStatus();
    log(`连上了(epoch=${state.epoch},fast=${info.fastReconnect === true}),覆盖下界 ${state.connectedFrom}`);
    void refreshChannels(core);
  });

  core.onEvent("message", (frame) => {
    const item = record(frame);
    if (!item) return;
    const key = `${item.ch}:${item.ts}`;
    if (seen.has(key)) return;
    seen.add(key);
    if (seen.size > 20000) seen.clear();   // 去重只防短时重复,清空最多是多写一条
    state.lastFrameAt = item.ts;
    state.frames += 1;
    if (SMOKE) { smokeCount += 1; smokeChannels.add(item.ch); return; }
    try { fs.appendFileSync(EVENTS, `${JSON.stringify(item)}\n`, { mode: FILE_MODE }); }
    catch (err) { log(`写事件失败:${err.message}`); }
    if (item.user) void resolveUser(core, item.user);
  });

  core.onAuthEvent((evt) => {
    if (evt.type === "dead") {
      state.wsState = "AUTH_DEAD";
      writeStatus();
      log(`会话失效(${evt.reason})—— 重新登录 slackcli 之后再起 daemon。probe 会自动退回轮询`);
      process.exit(3);
    }
    log(`令牌刷新(${evt.trigger})`);
  });

  state.wsState = "CONNECTING";
  writeStatus();
  await core.connect();

  if (SMOKE) {
    await new Promise((r) => setTimeout(r, SMOKE * 1000));
    // 只打统计,不打正文:冒烟输出会进终端和日志
    process.stdout.write(`${JSON.stringify({
      ok: true, seconds: SMOKE, ws_state: core.wsState, frames: smokeCount,
      channels: smokeChannels.size, covered_from: coveredFrom(),
    })}\n`);
    core.disconnect();
    process.exit(0);
  }

  // 故意**不** unref:这些定时器就是 daemon 活着的理由。unref 之后 socket 一旦没留句柄,
  // node 会直接静默退出,连一行日志都没有,查不出「daemon 为什么没了」。
  setInterval(() => { state.wsState = core.wsState; writeStatus(); flushUsers(); }, 5000);
  setInterval(trim, 10 * 60 * 1000);
  setInterval(() => void refreshChannels(core), 10 * 60 * 1000);
  process.on("exit", (code) => log(`daemon 退出(code=${code})`));
}

main().catch((err) => {
  state.wsState = "ERROR";
  try { writeStatus(); } catch { /* 起不来时状态目录可能都没有 */ }
  process.stderr.write(`${err.message}\n`);
  log(`起不来:${err.message}`);
  process.exit(2);
});
