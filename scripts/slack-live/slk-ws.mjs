#!/usr/bin/env node
// 用 slkcli 的凭据连 Slack RTM,把收到的 message 事件逐行以 JSON 打到 stdout,断线后退避重连。
// 连上时打一行 {"type":"hello"},调用方据此在重连后用 search 补拉断线期间的消息。
// token、cookie 和 RTM 地址(带 ticket)都不打印。

import WebSocket from "ws";
import { slackApi, getCredentials } from "./slkcli.mjs";

const PING_MS = 30_000;
const PONG_TIMEOUT_MS = 60_000;
const ATTACHMENT_KEYS = ["pretext", "title", "text", "fallback", "author_name"];

const emit = (obj) => process.stdout.write(JSON.stringify(obj) + "\n");
const warn = (msg) => process.stderr.write(`${new Date().toISOString()} ${msg}\n`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function slim(ev) {
  return {
    type: "message",
    channel: ev.channel,
    ts: ev.ts,
    thread_ts: ev.thread_ts,
    user: ev.user,
    username: ev.username || ev.bot_profile?.name,
    bot_id: ev.bot_id,
    subtype: ev.subtype,
    text: ev.text || "",
    attachments: (ev.attachments || []).map((a) => Object.fromEntries(ATTACHMENT_KEYS.map((k) => [k, a[k]]))),
    files: (ev.files || []).map((f) => ({ filetype: f.filetype, name: f.name })),
  };
}

function connectOnce() {
  return new Promise(async (resolve) => {
    let ws;
    try {
      const { cookie } = await getCredentials();
      const r = await slackApi("rtm.connect", {});
      if (!r.ok) throw new Error(`rtm.connect: ${r.error}`);
      // 桌面 app 的 xoxc token 要带 d cookie 才能握手,不带会收到 invalid_auth 后断开
      ws = new WebSocket(r.url, { headers: { Cookie: `d=${cookie}` } });
    } catch (e) {
      warn(`连接失败: ${e.message}`);
      return resolve(false);
    }
    let lastPong = Date.now();
    let pingId = 0;
    let gotHello = false;
    const timer = setInterval(() => {
      if (Date.now() - lastPong > PONG_TIMEOUT_MS) {
        warn("pong 超时,断开重连");
        ws.terminate();
        return;
      }
      if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ id: ++pingId, type: "ping" }));
    }, PING_MS);
    ws.on("message", (data) => {
      let ev;
      try { ev = JSON.parse(data.toString()); } catch { return; }
      lastPong = Date.now();
      if (ev.type === "hello") { gotHello = true; emit({ type: "hello" }); }
      else if (ev.type === "error") warn(`服务端报错: ${JSON.stringify(ev.error)}`);
      else if (ev.type === "goodbye") ws.close();
      else if (ev.type === "message" && ev.channel && ev.ts && !ev.hidden) emit(slim(ev));
    });
    ws.on("error", (e) => warn(`ws 错误: ${e.message}`));
    ws.on("close", (code) => {
      clearInterval(timer);
      warn(`连接关闭 code=${code}`);
      resolve(gotHello);
    });
  });
}

let backoff = 1_000;
for (;;) {
  const healthy = await connectOnce();
  backoff = healthy ? 1_000 : Math.min(backoff * 2, 60_000);
  await sleep(backoff);
}
