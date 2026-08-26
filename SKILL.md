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
| `probe-slack-thread.sh` | 一条 thread 的回复 | `CHANNEL` `THREAD_TS` `SELF` |
| `probe-pr-and-slack.sh` | 上面两个合成**一个** watch | `REPO` `PR` `GITHUB_SELF` `CHANNEL` `THREAD_TS` `SLACK_SELF` |
| `probe-http-json.sh` | 任意返回 JSON 列表的接口 | `URL` `MAP` |

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

### 3. 启动循环

用 Bash 工具,`run_in_background: true`:

```bash
export REPO=owner/repo PR=1234 SELF=your-login
~/.claude/skills/incremental-watch/scripts/watch-loop.sh \
  --name pr-1234 \
  --probe ~/.claude/skills/incremental-watch/scripts/templates/probe-github-pr.sh \
  --interval 120 --max-runtime 5400
```

启动后告诉用户三件事:盯的是什么、多久查一次、什么情况会叫醒你。别让人猜。

### 4. 被唤醒后

harness 的通知里带退出码。状态目录 `~/.claude/watch/<name>/` 里有两个文件,分工是硬的:

- **`inbox.json`** —— 真实数据项,累积去重。循环只做 merge 追加,不会丢弃未处理项;
  清空是你的事。唯一的例外是 `--seed`,它会把 inbox 重置成 `[]`,所以别对一个正在跑的
  watch 重新 seed
- **`signal.json`** —— 这次为什么退出,每次覆盖

按码分支:

| 码 | 含义 | 你该做什么 |
|---|---|---|
| 10 | 有新增项 | 读 `inbox.json` 处理。**别自己再去翻源** —— probe 已经过滤好了,重新拉一遍等于把省下的上下文又灌回来。处理完把 inbox 写成 `[]`,然后重新拉起循环 |
| 11 | 命中终止条件 | terminal 项也在 `inbox.json` 里(通常是最后一项)。收尾汇报,不要再拉起 |
| 12 | probe 出错 | 读 `signal.json` 的 `detail` 和 `log`。**先修好再拉起**,否则每轮都叫你一次,比不省 token 更糟 |
| 13 | 跑满 max-runtime | 没有新东西。原样重新拉起,不用汇报(除非用户在等状态) |

12 和 13 不动 `inbox.json`。所以拉起之前先看一眼 inbox —— 里面可能还有上一轮没处理完的项。

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
- `--max-runtime`:默认 90 分钟。到点退出 13 让你重新拉起,顺便给你一个「这事还没完」
  的检查点。长盯的场景可以调大,但别取消 —— 一个永不退出的后台循环没人知道它还活着
- `--active` / `--active-days`:只在工作时段轮询。注意它**只压 probe 次数,不压 max-runtime
  唤醒** —— 计时不看活动窗口,跨夜跑照样会在跑满时 exit 13 把你叫起来。真要过夜省钱,
  把 `--max-runtime` 调大

## 局限

- **app 退出会带走后台循环。** 它是 claude 进程的子进程。用户重启 app 之后需要重新拉起,
  循环自己不知道这件事
- **一个 name 只能有一个循环。** 脚本用目录锁保证;同名启动时若旧循环还活着就退出 1,
  旧循环已死则接管过期锁
- **不要用它盯 harness 自己就能通知你的东西。** 后台任务、subagent 完成时你本来就会被
  唤醒,再套一层 watch 是纯浪费
- 机器睡眠期间循环也睡,醒来后继续,不补跑

## 文件

- `scripts/watch-loop.sh` —— 通用循环。游标、inbox 合并去重、锁、退出码、活动窗口都在里面
- `scripts/templates/` —— 现成 probe(GitHub PR / CI checks / Slack thread / PR+Slack 合并 /
  HTTP JSON),配置走环境变量,直接可用。`_lib.sh` 里有 `require_env` 和 `run_with_timeout`
- `references/sources.md` —— 怎么挑模板、怎么自己写一个
- `references/mechanics.md` —— 这个形状是怎么试出来的:实测过的平台行为、以及 cron 和
  scheduled-task 两条路为什么走不通。改动 `watch-loop.sh` 之前先读这个,免得重踩

状态都在 `~/.claude/watch/<name>/`:

| 文件 | 谁写 | 说明 |
|---|---|---|
| `cursor` | 循环 | 已消费到哪。**落 inbox 之后才推进**,所以中途挂掉不会丢事件 |
| `inbox.json` | 循环 merge 追加 / **你清空** | 待处理的数据项,去重后按 `at` 排序。`--seed` 会重置它 |
| `signal.json` | 循环覆盖 | 这次为什么退出 |
| `log` | 循环追加 | 每轮一行。probe 的 stderr 也在这 |
| `meta.json` | 循环 | 启动参数和 pid |
| `lock/` | 循环 | 目录锁,同名只允许一个循环 |
