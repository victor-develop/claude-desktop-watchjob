# Slack 实时监听模板(`scripts/slack-live/`)

一个常驻脚本:通过 WebSocket 实时收 Slack 消息,在本地筛出「私聊我、@我、@我所在的组、我投递过的
thread 里的后续消息」,剩下的用 haiku 初判,需要处理的投递进一个 Claude Desktop 会话,由那个会话读线程、
分析、起草回复。监听和过滤不调用模型,只有过了过滤的消息才花一次初判。

它和 `probe-slack.sh` 的分工:probe 是「定时拉一个频道或 thread,有新东西叫醒 agent」,适合盯一件具体
的事;这个模板是「盯住所有找我的消息」,消息是推过来的,一两秒内收到。

## 流程

```
slk-ws.mjs  ── RTM WebSocket,每条 message 事件一行 JSON ──┐
search.messages 补拉(连上、重连时各一次,之后每 BACKFILL_SECONDS)┤
                                                            ▼
slack-live.py
  ├─ 本地过滤:私聊 / 正文含 <@我> / 含我所在用户组 / 投递过的 thread 后续
  │           跳过:我自己的消息(@我自己的除外,带 agent 前缀的照样跳过)、SKIP_SENDERS、
  │                 附件含 SKIP_ATTACHMENT_KEYWORDS、改消息删消息事件、启动前的历史消息
  ├─ 初判:常驻 `claude -p --tools ""`(stream-json),每条判完发 /clear
  │        真人私聊、只有文件的消息、我 @ 自己的消息不判,直接投
  └─ 投递:scripts/watch-relay.sh --note-file
           投不出去进 state.json 的 pending,每 RELAY_RETRY_SECONDS 秒重投,重启后接着投
```

- **实时通道和补拉按 ts 去重**,同一条只处理一次。补拉只覆盖 @我、`to:me` 和我所在的组;thread 后续
  消息只从实时通道来。
- **初判时带上 thread 前文**:线程回复会取根消息加最近几条(`conversations.replies`),小模型按上下文判断。
- **thread 后续**:频道里一条消息投递之后,它所在的 thread 记进 `state.json` 的 `threads`,之后这个 thread
  里别人发的、没 @我 的消息也走初判(机器人发的不算)。超过 `FOLLOW_THREAD_DAYS` 天没有新投递的 thread 不再跟。
- **投递内容不带消息原文**:只有类型、发送人、channel、ts、链接和初判理由。消息里夹带的指令到不了目标会话,
  会话自己用 Slack 工具读原文。初判时原文包在 `<slack-message>` 标签里,并写明是数据不是指令。
- **常驻初判进程**:省掉每条几秒的冷启动。进程退出、超时或输出异常时杀掉,下一条再拉起。

## 前置依赖

- **macOS,装着 Slack 桌面 app 并保持登录。** Slack 调用走 [slkcli](https://github.com/therohitdas/slkcli)
  (npm 包 `slkcli`,MIT):它从桌面 app 的本地存储读 `xoxc` token,从 Cookies 库读 `d` cookie(用钥匙串里的
  `Slack Safe Storage` 解密,用的是 `security find-generic-password`)。token 和 cookie 只在 slkcli 进程内使用,
  本模板不打印、不写日志、不放进仓库;slkcli 自己会把 token 缓存在 `~/.local/slk/token-cache.json`。
- Node(带 `fetch` 的版本,18 以上)和 Python 3(只用标准库)。
- `claude` CLI 已登录。初判和投递都是 `claude -p` 调用,走你账号的额度。
- 依赖装在模板目录里:

```bash
cd scripts/slack-live && npm install --ignore-scripts   # slkcli@0.2.0 和 ws@8.22.1,版本钉死
```

已经有一份 slkcli 本地 checkout 的,可以设 `SLKCLI_DIR=<checkout 路径>`,`slk-api.mjs` 和 `slk-ws.mjs` 改从那里加载。

## 配置

全部是环境变量,没有一项默认指向某个人的账号、频道或会话。

| 变量 | 默认 | 说明 |
|---|---|---|
| `WATCH_TARGET_SESSION_LINK` | 必填(或下面两项之一) | 目标会话链接 `claude://claude.ai/epitaxy/local_<id>`,按 id 投递,也用来唤醒。见 `scripts/watch-relay.sh` 顶部注释 |
| `WATCH_TARGET_SESSION_ID` / `WATCH_TARGET_SESSION` | 空 | 会话 id,或会话标题(备选) |
| `WATCH_RELAY_PERMISSION_MODE` | `auto` | 投递进程的权限模式,**要和目标会话一致**,否则消息被 Desktop 挂起等人批准,而脚本以为已送达 |
| `SLACK_LIVE_STATE_DIR` | `~/.claude/watch/slack-live` | `state.json`、`log`、初判进程的工作目录 |
| `TRIAGE_MODEL` | `haiku` | 初判模型 |
| `BACKFILL_SECONDS` | `300` | search 补拉间隔 |
| `RELAY_RETRY_SECONDS` | `60` | 投递失败后重投间隔 |
| `FOLLOW_THREAD_DAYS` | `7` | 投递过的 thread 跟多少天,每投递一条重新计时 |
| `SKIP_SENDERS` | 空 | 逗号分隔的发送人 username(不区分大小写),直接跳过。CI、审批机器人放这里 |
| `SKIP_ATTACHMENT_KEYWORDS` | 空 | 逗号分隔的关键词,附件的 pretext、text、fallback、author_name 含任一个就跳过 |
| `SLACK_QUERY` | `@<你的 handle>` | 补拉 @我 用的搜索语句;私聊固定另搜 `to:me` |
| `AGENT_MARK` / `AGENT_MARK_RE` | 空 | agent 用你本人账号发言时带的前缀(字面 startswith / 正则),和 `templates/probe-slack.sh` 同一套约定。你自己发的、@了自己的消息会被收下投递,带这个前缀的除外,免得 agent 代你发的消息又把自己叫醒 |
| `SLKCLI_DIR` | 空 | 用本地 slkcli checkout 代替 npm 包 |

## 运行

```bash
export WATCH_TARGET_SESSION_LINK="claude://claude.ai/epitaxy/local_<id>"
export WATCH_RELAY_PERMISSION_MODE=auto          # 和目标会话一致
export SKIP_SENDERS="github,approvals"           # 按你的工作区填
nohup python3 scripts/slack-live/slack-live.py >/dev/null 2>&1 & disown
tail -f ~/.claude/watch/slack-live/log
```

要开机常驻,写一个 launchd plist 跑同一条命令,把这些环境变量写进 `EnvironmentVariables`,`KeepAlive` 设 true。

`state.json` 里的 `started_at` 是首次启动时间,更早的消息只记账不触发,所以第一次启动不会把历史 @ 全部投一遍。
删掉 `state.json` 会重置这个基准。

## 已知限制

- **权限模式不一致时投递会被挂起**,而 SendMessage 照样返回成功,脚本不重投。见 `references/mechanics.md`。
  `WATCH_RELAY_PERMISSION_MODE` 要手动和目标会话对齐;会话登记文件里没有权限模式字段,对不齐时脚本发现不了。
- 群私聊(mpim)只有正文 @我 或 @我所在的组时才会收。
- 只在 macOS 上实测过;slkcli 读凭据的方式依赖 macOS 的 Slack 桌面 app 和钥匙串。

## 测试

`tests/test-slack-live.sh`:Slack 接口、WebSocket、`claude` 初判和投递全换成桩,用 `--exit-on-eof` 回放一段
事件流。`--exit-on-eof` 让脚本读完事件流就退出、不重启 slk-ws,也可以用来回放一段录下来的事件排查问题。
