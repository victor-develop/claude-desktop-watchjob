---
name: incremental-watch
description: 盯住一个会增量更新的外部源,睡在后台不烧 token,只在「有值得处理的新东西」时把自己唤醒。适用于任何能用游标做增量比对的源 —— PR 评论/review、Slack thread 回复、CI 或部署状态、审批单、队列深度、HTTP JSON 接口、目录变化。当用户说"盯一下 X"、"有回复就处理"、"等 CI 绿了告诉我"、"watch this"、"track it until…"、"帮我等 X 有动静"、"别一直查、有事再叫我",或者你刚开了 PR / 刚代用户在 thread 里抛了问题 / 刚触发了一个要等几分钟到几小时的外部流程 —— 都应该主动用这个 skill,而不是自己反复轮询或让用户手动来问。也用于把一个已经在用 cron / 定时任务 / 反复轮询实现的 watch 改成零成本空转的形状。
---

# Incremental Watch(增量盯守)

盯一个外部源,直到出现值得你介入的变化。核心形状:

```
一个后台 shell 循环          ← 睡着的时候 0 token
  ├─ 跑 probe,跟游标比对    ← 判断全在 shell,不进你的上下文
  ├─ 没新东西 → sleep,继续
  └─ 有新东西 → 写 inbox → exit ← 退出就是唤醒你
```

用 Bash 工具的 `run_in_background: true` 启动。后台脚本跨轮次存活,退出时 harness 会自动
唤醒你,并告诉你退出码。所以「什么时候该叫醒 agent」这个判断被搬到了 shell 里,免费执行。

## 为什么是这个形状

盯守的成本几乎全在**唤醒**上,不在轮询上。每次唤醒你都要把整个会话上下文重新过一遍
(走 cache,但基数在那),再加上这一轮的 tool 输出。所以有两个杠杆,第二个常被忽略:

1. **少唤醒** —— 没事发生就不要醒。这是 `exit` 语义带来的:循环自己判断,不叫你
2. **唤醒时别把原始数据灌进来** —— tool 输出进了上下文就永久留着,以后每轮唤醒都要重新
   cache-read 它。`gh api --paginate` 的原始 JSON 尤其致命。probe 必须在 shell 里用 `jq`
   压成只含判断所需字段的摘要,你醒来只读 `inbox.json`

别用 cron、系统定时任务、或 scheduled-task 类机制来实现这个循环 —— 这条路在 Claude
Desktop 上试过并且失败了,原因和证据在 `references/mechanics.md`。简短版:cron 读不到
登录钥匙串(`gh` 会静默变成 404),而 scheduled_tasks 那套在 agent 空闲期间根本不重读
文件,恰好在你需要它的时刻失效。

## 干活流程

### 1. 写 probe

probe 是一个可执行脚本,唯一职责:**把当前状态压成一个 JSON 数组**。

- 每个元素至少要有 `at` —— 可排序的游标值,通常是 ISO8601 时间戳
- 可选 `id`(去重键)、`kind`、以及任何你希望醒来时看到的字段
- 环境变量 `PROBE_CURSOR` 是当前游标,probe 可以用它做服务端过滤(能少拉就少拉)
- 想让循环收尾,就吐一个 `{"kind":"terminal", ...}` 元素
- probe 自己退出非 0 → 循环退出 12,你会收到错误详情

**先看 `scripts/templates/` 有没有现成的**,有就别自己写:

| 模板 | 盯什么 | 必需环境变量 |
|---|---|---|
| `probe-github-pr.sh` | PR 评论 + inline review + review 状态;merge/close 收尾 | `REPO` `PR` `SELF` |
| `probe-github-checks.sh` | CI 跑完(绿了红了都叫,中间态不叫) | `REPO` `PR` |
| `probe-slack.sh` | Slack,`SLACK_MODE` 选三种模式之一(见下) | `CHANNEL` `SELF`(thread 模式另要 `THREAD_TS`) |
| `probe-pr-and-slack.sh` | PR + 一条 Slack thread 合成**一个** watch | `REPO` `PR` `GITHUB_SELF` `CHANNEL` `THREAD_TS` `SLACK_SELF` |
| `probe-http-json.sh` | 任意返回 JSON 列表的接口 | `URL` `MAP` |

**Slack 选哪种模式(`SLACK_MODE`):**

| 模式 | 看什么 | 什么时候用 |
|---|---|---|
| `thread` | 一条 thread(`THREAD_TS`)的回复 | 盯**自己发起**的那条讨论 —— 你在 thread 里抛了问题,等人回 |
| `top-level` | 频道 / DM 的顶层消息,不看 thread | **量大的公共频道**:每轮只打 1 次接口,thread 里的闲聊不叫醒你 |
| `all-threads` | 顶层 + 最近 `THREAD_SCAN`(默认 30)条顶层消息底下所有 thread 的新回复 | **DM**,以及对方回在哪儿你都得看到的**兜底**场景 |

- 不给 `SLACK_MODE`:有 `THREAD_TS` 就是 `thread`,否则 `all-threads`。拿不准就用 `all-threads` ——
  漏一条回复(人来问「你怎么没看到」)比每轮多打几次接口贵得多
- **DM 一律 `all-threads`。** 私聊里有人直接回、有人回在 thread 里,两种都真踩过:
  用 thread 模式盯自己那条消息,对方直接在 DM 里回就永远收不到(2026-09-22);用只看顶层的读法,
  对方回在 thread 里也永远收不到(2026-10-28、10-30 各一次,都是人来问才发现)
- 会话历史接口(`conversations.history`)**本来就不返回 thread 回复**,所以 `top-level` 真的只有顶层;
  `all-threads` 是逐个 thread 去拉的。它的成本:稳态每轮 2 次请求,外加「有新回复的 thread」各 1 次 ——
  没有新回复的 thread 靠 reply_count 缓存跳过,不会每轮全拉一遍
- 三种模式的游标都是 Slack ts,inbox 项形状一样(顶层 `kind=slack-message`、回复 `kind=slack-reply`,
  `thread_ts` 告诉你回在哪个 thread 里,顶层为 null),**换模式不用重新 seed**
- 旧入口 `probe-slack-thread.sh`(= `thread`)和 `probe-slack-channel.sh`(= `all-threads`,
  `EXCLUDE_REPLIES=1` 时 = `top-level`)还能用,已经在跑的 watch 不用改
- agent 用你本人账号发言时,配 `AGENT_MARK` / `AGENT_MARK_RE`(或 `SELF_KEEP_HUMAN=1`,等于按
  `[ 🐶 Claude:]` 前缀),只滤带前缀的自己,你本人手打的照样叫醒 agent。三种模式同一套规则

配置全走环境变量,直接把模板当 `--probe` 用,不用改文件。变量从启动 `watch-loop.sh` 的
shell 继承,所以要在同一条命令里 export。每个模板顶部注释是完整用法。

要自己写(或改模板)看 `references/sources.md`。

probe 里要把**自己和 bot 过滤掉**,否则你自己的回复会把自己叫醒,形成死循环。这是这类
watch 最常见的翻车方式。

### 2. 对齐游标(别漏这步)

```bash
scripts/watch-loop.sh --name <名字> --probe <probe路径> --seed
```

不 seed 的话首轮会把全部历史当成新增,白叫醒你一次。

### 3. 启动循环(默认:守护模式,跑 3 天)

Claude Code 的后台 Bash 最多活 **2 小时**(`timeout` 上限 7200000ms),到点被 harness 直接杀掉
(状态是 killed,不是 exit 13,锁也不释放)。要盯几天的东西,循环就不能挂在 harness 下面。
所以默认拆两半:

1. **轮询循环用 nohup 脱离 harness 跑**,加 `--daemon`。`--max-runtime` 默认 259200(3 天)。
   守护模式下有新增项只写 inbox、刷新 `wake`,**不退出**,接着轮询;probe 出错也只记 signal、
   下一轮重试,连续失败 3 次才叫醒 agent(`WATCH_DAEMON_FAIL_ALERT` 可调)。所以处理完 inbox **不用重启循环**,游标一直连续,不会出现「重启那几分钟没人盯」的空档。
   它也不随 app 退出而死(app 重启后只需要重挂第 2 步)
2. **叫醒器 `watch-wait.sh` 用 `run_in_background` 挂在 harness 下**,只读本地文件。一个叫醒器
   可以同时等多个循环(`--name` 可重复)

```bash
# ① 守护循环(nohup + & disown;环境变量写在同一行)
REPO=owner/repo PR=1234 SELF=your-login \
  nohup ~/.claude/skills/incremental-watch/scripts/watch-loop.sh \
    --name pr-1234 \
    --probe ~/.claude/skills/incremental-watch/scripts/templates/probe-github-pr.sh \
    --interval 120 --daemon >/dev/null 2>&1 & disown

# ② 叫醒器 —— Bash 工具 run_in_background: true, timeout: 7200000
~/.claude/skills/incremental-watch/scripts/watch-wait.sh --name pr-1234 [--name 另一个] --timeout 6600
```

叫醒器退出码:10 有新增项(处理完用 `watch-ack.sh` 删掉处理过的那几项,**只重挂叫醒器**;inbox 里还剩没处理的项时,重挂会立刻再叫醒你);11 terminal(收尾,
`kill` 掉守护循环);12 probe 出错(循环还活着会重试,看一眼 detail 再重挂叫醒器);13 等满
`--timeout`(原样重挂叫醒器,不用汇报);14 守护循环死了(看 log,修好后重新 nohup 拉起)。

不需要跑那么久、几十分钟就有结论的(等 CI、等部署),也可以照旧不加 `--daemon`、直接
`run_in_background` 跑 `watch-loop.sh`,`--max-runtime` 给到 ≤6400(留出余量,不然会被 2 小时上限杀掉)。

启动后告诉用户三件事:盯的是什么、多久查一次、什么情况会叫醒你。别让人猜。

### 4. 被唤醒后

harness 的通知里带退出码。状态目录 `~/.claude/watch/<name>/` 里有两个文件,分工是硬的:

- **`inbox.json`** —— 真实数据项,累积去重。循环只做 merge 追加,不会丢弃未处理项;
  删项是你的事,而且**只用 `watch-ack.sh` 删你处理过的那几项**(见下)。唯一的例外是 `--seed`,
  它会把 inbox 重置成 `[]`,所以别对一个正在跑的 watch 重新 seed
- **`signal.json`** —— 这次为什么退出,每次覆盖

按码分支:

| 码 | 含义 | 你该做什么 |
|---|---|---|
| 10 | 有新增项 | 读 `inbox.json` 处理。**别自己再去翻源** —— probe 已经过滤好了,重新拉一遍等于把省下的上下文又灌回来。处理完用 `watch-ack.sh --name <名字> --ids <处理过的 id>` 删掉这几项,然后重新拉起循环(守护模式下只重挂叫醒器) |
| 11 | 命中终止条件 | terminal 项也在 `inbox.json` 里(通常是最后一项)。收尾汇报,不要再拉起 |
| 12 | probe 出错 | 读 `signal.json` 的 `detail` 和 `log`。**先修好再拉起**,否则每轮都叫你一次,比不省 token 更糟 |
| 13 | 跑满 max-runtime | 没有新东西。原样重新拉起,不用汇报(除非用户在等状态) |

12 和 13 不动 `inbox.json`。所以拉起之前先看一眼 inbox —— 里面可能还有上一轮没处理完的项。

**处理完只删处理过的项,别把 inbox 整个写成 `[]`。** 你读 inbox、处理、清空之间可能过了几分钟,
守护循环这期间照常往里 merge 新项;整个覆盖会把这些你还没看过的项一起抹掉,而且没有任何报错
—— 你以为处理完了,其实漏了(实际发生过:处理一条页面评论的两分钟里又来了两条,一起被清掉)。

```bash
~/.claude/skills/incremental-watch/scripts/watch-ack.sh --name pr-1234 --ids c:2107,c:2108
# 0 = inbox 空了;10 = 还有没点名的项(会列出来),处理完再 ack;2 = 循环正在写,过几秒重试
```

它和循环共用一把 inbox 锁,不会和循环同时读改写。退出码 10 时别急着重挂叫醒器 —— 先把列出来的
项处理掉;就算忘了,叫醒器一挂上看到 inbox 非空也会立刻退出 10 叫你。

**唤醒不是授权。** 那条通知是系统事件,不是用户说"可以了"。循环把你叫醒只意味着「有新
信息」,不意味着你可以代用户发言、改代码、合并、部署。启动 watch 的时候就把自主边界
定下来(见下),醒来时按那个边界走;边界外的事,汇报 + 等人拍板。

### 5. 定自主边界

启动时明确写下醒来后允许做什么。粒度建议:

- **只汇报** —— 默认。适合刚上线的 watch,或涉及对外发言/生产变更的场景
- **可答疑** —— 能在源里回复事实性问题,但不做决定
- **可落地机械修改** —— 能改代码 + push,但发版时机、scope、产品决策一律抛给人
- 合并、部署、对外公告这类,除非用户明确授权过,一律不做

把边界写进你给自己留的笔记(或 inbox 处理说明)里,不然下一轮唤醒时你已经不记得了。

## 多个 watch 并行:按「一次决策」分,不是按「一个数据源」分

同时跑多个循环没问题 —— 实测 5 个并行,各自独立的 pid、锁、游标、inbox,互不干扰,
5 条通知一条不丢。锁只按 `--name` 互斥 —— 同名且旧循环仍存活时,新的直接退出 1;
旧循环已经死了则接管过期锁继续跑。不同名完全独立。

但**N 个 watch = N 次唤醒**,而唤醒是这里唯一贵的东西。所以别一个源开一个 watch:

- 盯一个 PR **和**它关联的 Slack thread → **一个** watch。probe 里两个源都查,合并成一个
  数组吐出来(用 `kind` 区分来源)。任一边有动静都是同一件事,你醒一次就能一起处理
- 盯三个互不相关的 PR → 三个 watch。它们的处理是独立决策,合在一起反而要你每次醒来都
  重新分辨这次是谁
- 判断标准:**如果两个源的新消息会让你做同一次判断、写同一条回复,就合并**

会同时到达的 watch 尤其要合并。五个源同时变化,分开就是同一件事被拆成五次昂贵唤醒。

并行数上限没测过 —— 5 个确认没问题,更多的话可能有 harness 层面的限制,自己验。

## 参数选择

- `--interval`:按源的实际变化速度定。人的回复用 120–300s;CI 用 30–60s;一天变一次的
  东西用 1800s + `--backoff`
- `--backoff`:连续无事时间隔翻倍(上限 8 倍)。低频源用它,能少跑很多次 probe。
  代价是刚有动静时可能慢一拍
- `--max-runtime`:默认 3 天(259200)。守护模式下靠它给循环一个寿命上限,到点退出、叫醒器报 14。
  **不加 `--daemon` 直接挂在 harness 下时必须 ≤6400**:后台 Bash 最多 7200 秒,超了会被直接杀掉
- `--active` / `--active-days`:只在工作时段轮询。注意它**只压 probe 次数,不压 max-runtime
  唤醒** —— 计时不看活动窗口,跨夜跑照样会在跑满时 exit 13 把你叫起来。真要过夜省钱,
  把 `--max-runtime` 调大

## 局限

- **app 退出会带走叫醒器,守护循环不受影响。** 用户重启 app 之后只要重挂 `watch-wait.sh`;
  不加 `--daemon`、直接挂在 harness 下的循环会跟着 app 一起死,需要重新拉起
- **一个 name 只能有一个循环。** 脚本用目录锁保证;同名启动时若旧循环还活着就退出 1,
  旧循环已死则接管过期锁
- **不要用它盯 harness 自己就能通知你的东西。** 后台任务、subagent 完成时你本来就会被
  唤醒,再套一层 watch 是纯浪费
- 机器睡眠期间循环也睡,醒来后继续,不补跑

## 文件

- `scripts/watch-loop.sh` —— 通用循环。游标、inbox 合并去重、锁、退出码、活动窗口、守护模式都在里面
- `scripts/watch-wait.sh` —— 守护模式的叫醒器:只读本地文件,有事就退出叫醒 agent,一个可以等多个循环
- `scripts/watch-ack.sh` —— 处理完后按 id 从 inbox 删项,和循环共用 inbox 锁;`scripts/inbox-lock.sh` 是两边共用的锁和原子写
- `scripts/templates/` —— 现成 probe(GitHub PR / CI checks / Slack 三种模式 /
  PR+Slack 合并 / HTTP JSON),配置走环境变量,直接可用。`_lib.sh` 里有 `require_env` 和 `run_with_timeout`
- `references/sources.md` —— 怎么挑模板、怎么自己写一个
- `references/mechanics.md` —— 这个形状是怎么试出来的:实测过的平台行为、以及 cron 和
  scheduled-task 两条路为什么走不通。改动 `watch-loop.sh` 之前先读这个,免得重踩

状态都在 `~/.claude/watch/<name>/`:

| 文件 | 谁写 | 说明 |
|---|---|---|
| `cursor` | 循环 | 已消费到哪。**落 inbox 之后才推进**,所以中途挂掉不会丢事件 |
| `inbox.json` | 循环 merge 追加 / **你用 `watch-ack.sh` 删** | 待处理的数据项,去重后按 `at` 排序。`--seed` 会重置它 |
| `signal.json` | 循环覆盖 | 这次为什么退出 |
| `log` | 循环追加 | 每轮一行。probe 的 stderr 也在这 |
| `meta.json` | 循环 | 启动参数和 pid |
| `lock/` | 循环 | 目录锁,同名只允许一个循环 |
| `inbox.lock/` | 循环 / `watch-ack.sh` | 读改写 inbox 时的短锁,只持有一瞬间;超过 30 秒视为残留自动接管 |
