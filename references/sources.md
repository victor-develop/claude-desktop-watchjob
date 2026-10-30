# 怎么写 probe

probe 的唯一职责:**把当前状态压成一个 JSON 数组**,每项带一个可排序的 `at`。
游标、去重、锁、退出码都归循环管,probe 只管「怎么读这个源」。

常见的源已经有现成模板,别从零写 —— 见 `scripts/templates/`:

| 模板 | 盯什么 | 必需的环境变量 |
|---|---|---|
| `probe-github-pr.sh` | PR 的评论 + inline review + review 状态;merge/close 时收尾 | `REPO` `PR` `SELF` |
| `probe-github-checks.sh` | CI 跑完没,绿了红了都叫你;中间态不叫 | `REPO` `PR` |
| `probe-slack.sh` | Slack,三种模式:一条 thread / 频道·DM 顶层 / 顶层 + 所有 thread 的新回复(见下) | `CHANNEL` `SELF`(thread 模式另要 `THREAD_TS`) |
| `probe-pr-and-slack.sh` | PR + 一条 Slack thread 合成一个 watch(见下) | `REPO` `PR` `GITHUB_SELF` `CHANNEL` `THREAD_TS` `SLACK_SELF` |
| `probe-http-json.sh` | 任意返回 JSON 列表的接口 | `URL` `MAP` |

Slack 只有一个入口 `probe-slack.sh`,用 `SLACK_MODE` 选模式:

| `SLACK_MODE` | 看什么 | 每轮请求数 | 什么时候用 |
|---|---|---|---|
| `thread` | `THREAD_TS` 那一条 thread 的回复 | 1 | 盯自己发起的那条讨论 |
| `top-level` | 频道 / DM 的顶层消息,不看 thread | 1 | 量大的公共频道 |
| `all-threads` | 顶层 + 最近 `THREAD_SCAN`(默认 30)条顶层消息底下所有 thread 的新回复 | 2 + 有新回复的 thread 数 | DM,以及「回在哪儿都得看到」的兜底场景 |

不给 `SLACK_MODE` 时:给了 `THREAD_TS` 就是 `thread`,否则是 `all-threads`。三种模式的游标都是
Slack ts,inbox 项形状一样(`{id, who, at, kind, thread_ts, body}`,顶层 `kind=slack-message`、
回复 `kind=slack-reply`),所以换模式不用重新 seed。

**会话历史接口拿不到 thread 回复。** `slackcli conversations read <channel>` 走的是
`conversations.history`,只返回顶层消息。想看 thread 回复只能逐个 thread 用 `--thread-ts` 去拉 ——
`all-threads` 就是这么做的,并且尽量少拉:父消息带 `latest_reply` 时(直接打 Slack API 才有,
slackcli 的 JSON 不带)用它和游标比;否则在 `THREAD_CACHE_DIR` 记一份「上次拉时 reply_count 是 n、
所有回复都不晚于 last」,这次 reply_count 没变且 last 不晚于游标就跳过。细节在模板头注释。

旧的 `probe-slack-thread.sh`(= `thread` 模式)和 `probe-slack-channel.sh`(= `all-threads`,
`EXCLUDE_REPLIES=1` 时 = `top-level`)还在,是转给 `probe-slack.sh` 的兼容入口,已经在跑的
watch 不用改。

`thread` 模式兼容两种 slackcli 命令形状,按顺序尝试、只有第一种失败才试第二种:

```text
1. slackcli conversations read <channel> --thread-ts <ts> --limit N --json   (0.9)
2. slackcli messages --channel <channel> --thread <ts> --json               (0.7 及更早)
```

另外两种模式只验证过 0.9.x,不做 0.7 回退。

输出结构也一并归一:0.7+ 把用户信息平铺在顶层 `users[]`、消息里只有 `.user`,模板按 id
关联出姓名;老版本消息自带 `.user_name` 就直接用。0.7+ 还会先往 stdout 打进度行
(`- Fetching messages...`),模板从第一个 `{` 开始截。两种形状都不认时报 exit 3,并把两次
尝试的 stderr 一起带出来 —— 不让它退化成「没有新消息」,那种失败最难发现。

配置全走环境变量,所以模板可以直接当 `--probe` 用,不需要改文件:

```bash
export REPO=owner/repo PR=123 SELF=your-login
scripts/watch-loop.sh --name pr-123 --probe scripts/templates/probe-github-pr.sh --seed
scripts/watch-loop.sh --name pr-123 --probe scripts/templates/probe-github-pr.sh --interval 120
```

环境变量是从启动 `watch-loop.sh` 的那个 shell 继承下来的,所以要在同一条命令(或同一个
`export` 之后)里给。每个模板顶部的注释是完整用法,包括可选参数。

## PR + thread 为什么要合成一个

`probe-pr-and-slack.sh` 存在的理由不是省事,是省唤醒:PR 上有人 review、thread 里有人
追问,对 agent 来说是**同一次判断、同一条回复**。拆成两个 watch 就是同一件事把它叫醒
两次,而唤醒是这套机制里唯一贵的东西。

反过来,三个互不相关的 PR 应该开三个 watch —— 那是三次独立决策,合在一起反而要 agent
每次醒来先分辨「这次是谁」。

它直接调用另外两个模板再合并,不复制代码。合并时把 Slack 的 `ts` 归一成 ISO8601 才能跟
GitHub 的时间戳排在一起,原始值留在 `raw_at`(回 Slack 时需要它)。

## 自己写一个

任何能吐结构化输出的东西都能接进来,映射出这三样即可:

| 你要提供 | 从哪来 | 没有的话 |
|---|---|---|
| `at` | 更新时间 / 递增序号 / 版本号 | 用内容 hash 配一个单调计数器;`id` 必须稳定 |
| `id` | 主键 | 可以省,循环会用 `[.who, .at]` 去重 |
| 摘要字段 | 只留够判断「要不要动作」的 | — |

约定:

- 环境变量 `PROBE_CURSOR` 是当前游标(首次为空),可以用来做服务端过滤,能少拉就少拉
- 想让循环收尾,吐一个 `{"kind":"terminal", ...}` 元素
- 自己退出非 0 → 循环退出 12。**probe 的 stderr 进 `log`**,`signal.json` 的 `detail` 里
  只有退出码 —— 所以出错时要看的是 `log`

输出不是 JSON 的 CLI,用 `jq -R -s 'split("\n")'` 或 `awk` 转一层。关键是**转换和过滤都
留在 shell 里** —— 原始输出一旦进了 agent 上下文就永久留着,以后每轮唤醒都要重新
cache-read。

`scripts/templates/_lib.sh` 里有三个可以直接用的:`require_bin`(缺命令时点名并给安装
地址)、`require_env`(缺参数时清晰报错,而不是吐半个数组)、`run_with_timeout`
(macOS 默认没有 `timeout(1)`,它会用看门狗兜底)。

## 两个必踩的坑

**滤掉自己和 bot。** 否则你自己的回复把自己叫醒,无限循环。GitHub 侧默认滤
`\[bot\]$|^web-flow$`,可以用 `BOT_RE` 加;Slack 侧滤 `bot_id != null` 和 join/leave
这类 `subtype`。

**所有网络调用都要设超时。** 循环挂掉是安全的 —— 它退出,agent 就被叫醒。但循环**挂死**
永远不退出,也就永远不叫醒任何人。这是这套机制里唯一不告警的失效方式。

## 写完先自查

```bash
PROBE_CURSOR="" ./probe.sh | jq .                          # 结构对不对、字段全不全
PROBE_CURSOR="<上面输出里最大的 at>" ./probe.sh | jq 'length'  # 应该是 0
```

第二条是关键。给了最新游标还返回非空,说明游标字段选错了,循环会无限叫醒你。

模板本身有测试兜底:`tests/test-templates.sh` 用 stub 的 `gh` / `slackcli` 和 `file://`
验过滤、排序、terminal 判定和合并逻辑;`tests/test-slack-modes.sh` 验 Slack 三种模式(thread 回复
抓得到、带前缀的自己被滤、游标推进、没变化的 thread 不重拉)。都不碰网络。
