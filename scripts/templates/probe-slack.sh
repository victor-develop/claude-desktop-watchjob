#!/bin/bash
# 盯 Slack 的统一入口。三种模式,一个参数 SLACK_MODE 切换:
#
#   thread       只看 THREAD_TS 那一条 thread 底下的回复。
#                盯自己发起、已经开起来的那条讨论用它。
#   top-level    只看频道 / DM 的顶层消息,不看任何 thread。
#                消息量大的公共频道用它:每轮只打 1 次接口。
#   all-threads  顶层消息 + 最近 THREAD_SCAN 条顶层消息底下所有 thread 的新回复。
#                DM、以及「对方回在哪儿都得看到」的兜底场景用它。
#
# 默认:给了 THREAD_TS 就是 thread,否则 all-threads(EXCLUDE_REPLIES=1 时是 top-level)。
# 漏一条回复的代价(人来问「你怎么没看到」)比每轮多打几次接口大得多,所以不给 THREAD_TS
# 时默认兜住 thread 回复;量大的频道自己切 top-level。
#
# probe-slack-thread.sh / probe-slack-channel.sh 是本文件的兼容入口,行为不变,
# 已经在跑的 watch 不用改配置、不用重新 seed。新 watch 直接用本文件。
#
# 为什么要 all-threads:频道读取走的是 `slackcli conversations read <channel>`,也就是
# conversations.history 接口,它**只返回顶层消息**,thread 里的回复不在里面(回复时勾了
# 「同时发到频道」的 thread_broadcast 例外,它两边都会出现,按 id 去重)。旧的频道模板
# 注释写着「默认包含 thread 回复」,是错的 —— 有人回在 thread 里,watch 一直报「无变化」,
# 前后踩过好几次,都是人来问才发现。thread 回复只能逐个 thread 用 --thread-ts 去拉。
#
# 用 slackcli(https://github.com/shaharia-lab/slackcli,开源,输出 JSON)。
# 换成直接打 Slack Web API 的 conversations.history / conversations.replies 也行,
# 只要最后吐出同样形状的数组。
#
# 配置(环境变量):
#   SLACK_MODE  可选  thread | top-level | all-threads,默认见上
#   CHANNEL     必需  频道 ID(C...)、私聊 channel ID(D...)或群聊(G.../mpim)。
#                     注意是 **channel ID**,不是对方的 user ID(U...)。
#                     D 开头的 ID 用 `slackcli conversations list --types im` 查
#   THREAD_TS   thread 模式必需  父消息的 ts,如 1700000000.000000。其它模式下忽略
#   SELF        必需  你自己的 Slack user ID(U...)。不填会被自己的消息叫醒,死循环
#               也可以用 SLACK_SELF —— 跟 GitHub 模板同时用时用它,免得两边互相覆盖
#   TIMEOUT     可选  单次请求超时秒数,默认 25
#   BODY_MAX    可选  正文截断长度,默认 280
#   LIMIT       可选  一页取多少条,默认 100
#   MAX_PAGES   可选  每次读取最多翻几页,默认 20
#   THREAD_SCAN 可选  all-threads 模式扫最近多少条顶层消息找 thread,默认 30。
#                     更早的顶层消息底下的新回复看不到 —— 这是用来控成本的上限
#   THREAD_CACHE_DIR 可选 all-threads 模式的 thread 缓存目录,默认 ${TMPDIR:-/tmp}/incremental-watch-slack
#   SNAPSHOT_LAG 可选 all-threads 模式的快照滞后秒数,默认 10(见下)
#   EXCLUDE_REPLIES 可选  旧参数,=1 等于 SLACK_MODE=top-level。和 SLACK_MODE=all-threads 同时给会报错
#   TERMINATE_RE 可选 正则;某条消息命中就报 terminal(比如 '结了|closed|done')
#
# 过滤自己(三种模式同一套规则):SELF 发的消息默认全滤掉。agent 用你本人账号发言时,
# 配一个「agent 前缀」,SELF 发的消息就只滤带前缀的,你本人手打的照样会叫醒 agent:
#   AGENT_MARK      固定前缀,按字面 startswith 匹配(如 '[ 🤖 agent ]')
#   AGENT_MARK_RE   同上,按正则匹配。Slack 会把 emoji 存成 :shortcode:,前缀里有 emoji 时
#                   用它,比如 '^\[ (:dog:|🐶) agent\]'
#   SELF_KEEP_HUMAN =1 且上面两个都没配时,等于 AGENT_MARK_RE='^\[ (:dog:|🐶) Claude:\]'
# 别人的消息即使引用了带前缀的话也不会被滤。bot 消息和 join/leave/pin 这类系统消息一律滤掉。
#
# 用法:
#   export CHANNEL=D0XXXXXXXXX SELF=U0XXXXXXXXX SLACK_MODE=all-threads
#   scripts/watch-loop.sh --name dm-x --probe scripts/templates/probe-slack.sh --seed
#   scripts/watch-loop.sh --name dm-x --probe scripts/templates/probe-slack.sh --interval 180
#
# 输出形状(三种模式一致):
#   {id: ts, who, at: ts, kind, thread_ts, body}
#   kind      顶层消息是 "slack-message",thread 里的回复是 "slack-reply"
#   thread_ts 回复所在 thread 的父消息 ts;顶层消息为 null。醒来要回消息时看它决定回哪儿
# 游标:三种模式都用 Slack ts。ts 是字符串化时间戳,字典序 == 时间序(2001 年之后都是
# 10 位整数部分),直接当游标;id 也是 ts,同一会话内唯一。所以**换模式不用重新 seed**:
# 从 top-level 换到 all-threads 后,游标之后发在 thread 里的回复会在下一轮补上来。
#
# all-threads 怎么控 API 成本(稳态每轮 2 次请求;有新回复的 thread 再各拉 2 轮):
#   1. 顶层:跟 top-level 一样,1 次 history(带 --oldest=游标)
#   2. 找 thread:1 次 history --limit THREAD_SCAN,只挑 reply_count > 0 的
#   3. 逐个 thread 判断要不要拉,能跳就跳:
#      a. 父消息带 latest_reply(直接打 Slack API 时有;slackcli 0.9–0.14 的 JSON 不带)
#         且 latest_reply <= 游标 → 跳过
#      b. 否则看缓存:上次拉这个 thread 时 reply_count 是 n,「会叫醒你的回复」(过滤掉自己
#         和 bot 之后剩下的)ts 都 <= last。这次 reply_count 还是 n、last <= 游标,并且这个
#         n 已经连续拉到过两次(stable)→ 跳过
#      c. 剩下的才拉,带 --oldest=游标,只取游标之后的回复
#   缓存的含义跟哪个 watch 的游标无关,只跟过滤规则有关(文件名里带过滤规则的摘要),所以
#   同一频道、同样过滤规则的多个 watch 可以共用一份。循环推进游标失败时 last > 游标,下一轮
#   照样重拉,不会漏。最后一条回复是你自己发的时候,它被滤掉,last 停在游标上,照样能跳过。
#   「连续两次才算 stable」是防 history 的 reply_count 已经加一、replies 接口却还没返回那条
#   回复:第二轮会再拉一次补上。代价:一轮之内有人删一条又回一条、reply_count 恰好不变,
#   这条会漏(直到下次 reply_count 变化)。缓存是空的那一轮(第一次跑、TMPDIR 被清)要把
#   THREAD_SCAN 范围内有回复的 thread 都拉一遍;缓存写不了就每轮都这样,结果不变,只是贵。
#
# all-threads 一轮要读好几次(顶层、各个 thread),读的时刻不同,但只推进一个游标。为了不让
# 后读到的较新回复把先读时还没出现的消息「越过去」,每轮开头取一个快照时刻
# SNAP = 现在 - SNAPSHOT_LAG(默认 10 秒),ts 晚于 SNAP 的项这一轮先不交出去,下一轮再给。
# 代价是新消息最多晚 SNAPSHOT_LAG 秒 + 一个轮询间隔叫醒你。
#
# 关于「取满一页」,两条实测结论,别混:
#   1. 读会话历史不带 --oldest 时,截断丢的是**最旧**的消息 —— Slack 返回的是最近 N 条。
#      所以就算一页装不下,最新的消息一定在里面,ts 游标不会漏唤醒。
#   2. **绝不能拿消息条数做变化检测。** 一页默认 100 条,长会话 / 长 thread 的返回条数
#      恒定顶在上限,条数永远不变,watch 会一直报「没新消息」。判断变化只看 ts。
# 翻页只用来保证「这一轮的新消息全都取到了」:
#   有游标:把 PROBE_CURSOR 当 --oldest(只返回严格晚于它的),取满一页或 has_more 就把
#     oldest 推到本页最大 ts 再取,直到到底。翻满 MAX_PAGES 仍不到底、或中途失败,probe
#     整体失败(exit 3),游标不动 —— 宁可叫醒 agent,也不静默截断丢事件。
#   没游标(只出现在 --seed):会话历史只取最新一页(seed 只要最新那条的 ts);thread 从头
#     往后翻完(thread 不带 oldest 时从最早的开始返回)。
# EXCLUDE_REPLIES / 只看顶层是本模板自己在 jq 里滤的,**没有**用 CLI 的 --exclude-replies:
# 那个 flag 在拿到一页之后本地筛,返回条数变成「筛剩下的」,「不满一页 = 到底了」的判据
# 就失真了(实测同一段区间 100 → 65)。
#
# CLI 会把进度行("- Fetching messages...")打到 stdout,偶尔还会在 JSON **后面**追一段
# "Update available: ..." 升级提示。json_only 只留从第一个 { 到最后一个 } 结尾的行。
#
# slackcli 版本:thread 模式验证过 0.7.x / 0.9.x / 0.14.x(0.7 只有 `messages` 子命令,自动回退,
# 但不能翻页,取满 LIMIT 就 fail closed);其它两种模式验证过 0.9.x / 0.14.x,不做 0.7 回退。其它版本 fail closed,
# 手跑确认 JSON 结构没变后用 SLACKCLI_ALLOW_UNTESTED=1 放行。

set -uo pipefail
. "$(dirname "$0")/_lib.sh"
require_bin slackcli jq
SELF="${SLACK_SELF:-${SELF:-}}"

# ---------- 模式 ----------
case "${EXCLUDE_REPLIES:-0}" in
  1|true|yes) NOREPLIES=1 ;;
  0|''|false|no) NOREPLIES=0 ;;
  *) echo "EXCLUDE_REPLIES 只接受 0/1,收到: '${EXCLUDE_REPLIES}'" >&2; exit 3 ;;
esac
MODE="${SLACK_MODE:-}"
if [ -z "$MODE" ]; then
  if [ -n "${THREAD_TS:-}" ]; then MODE=thread
  elif [ "$NOREPLIES" = "1" ]; then MODE=top-level
  else MODE=all-threads; fi
fi
case "$MODE" in
  thread|top-level|all-threads) : ;;
  *) echo "SLACK_MODE 只接受 thread / top-level / all-threads,收到: '$MODE'" >&2; exit 3 ;;
esac
if [ "$MODE" = "all-threads" ] && [ "$NOREPLIES" = "1" ]; then
  echo "EXCLUDE_REPLIES=1 和 SLACK_MODE=all-threads 互相矛盾。只看顶层用 SLACK_MODE=top-level" >&2
  exit 3
fi

if [ "$MODE" = "thread" ]; then require_env CHANNEL THREAD_TS SELF; else require_env CHANNEL SELF; fi

ver=$(slackcli --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
if [ "$MODE" = "thread" ]; then
  case "$ver" in
    0.7.*|0.7|0.9.*|0.9|0.14.*|0.14) : ;;
    *) [ "${SLACKCLI_ALLOW_UNTESTED:-0}" = "1" ] \
         || { echo "未验证的 slackcli 版本 '$ver'(已验证 0.7.x / 0.9.x / 0.14.x)。手跑一次确认 JSON 输出结构后,用 SLACKCLI_ALLOW_UNTESTED=1 放行" >&2; exit 2; } ;;
  esac
else
  case "$ver" in
    0.9.*|0.9|0.14.*|0.14) : ;;
    *) [ "${SLACKCLI_ALLOW_UNTESTED:-0}" = "1" ] \
         || { echo "未验证的 slackcli 版本 '$ver'(本模板 $MODE 模式已验证 0.9.x / 0.14.x)。手跑一次确认 JSON 输出结构后,用 SLACKCLI_ALLOW_UNTESTED=1 放行" >&2; exit 2; } ;;
  esac
fi

TIMEOUT="${TIMEOUT:-25}"
BODY_MAX="${BODY_MAX:-280}"
LIMIT="${LIMIT:-100}"
MAX_PAGES="${MAX_PAGES:-20}"
THREAD_SCAN="${THREAD_SCAN:-30}"
TERMINATE_RE="${TERMINATE_RE:-}"
SNAPSHOT_LAG="${SNAPSHOT_LAG:-10}"
case "$SNAPSHOT_LAG" in ''|*[!0-9]*) echo "SNAPSHOT_LAG 必须是非负整数,收到: '$SNAPSHOT_LAG'" >&2; exit 3 ;; esac

# 数值配置必须先校验:非数字的 MAX_PAGES 会让 -gt 比较每轮报错返回假,翻页上限静默失效,
# fail-closed 路径整个绕过;LIMIT 非数字则「取满一页」的判断同样失真。启动前挡住,exit 3
for pair in "MAX_PAGES:$MAX_PAGES" "LIMIT:$LIMIT" "TIMEOUT:$TIMEOUT" "BODY_MAX:$BODY_MAX" "THREAD_SCAN:$THREAD_SCAN"; do
  name=${pair%%:*}; val=${pair#*:}
  case "$val" in
    ''|*[!0-9]*) echo "$name 必须是正整数,收到: '$val'" >&2; exit 3 ;;
    0) [ "$name" = "BODY_MAX" ] || { echo "$name 不能是 0" >&2; exit 3; } ;;
  esac
done

MARK="${AGENT_MARK:-}"; MARKRE="${AGENT_MARK_RE:-}"
if [ -z "$MARK" ] && [ -z "$MARKRE" ] && [ "${SELF_KEEP_HUMAN:-}" = "1" ]; then
  MARKRE='^\[ (:dog:|🐶) Claude:\]'
fi

json_only() {  # 从第一行 { 或 [ 开头的起,到最后一行以 } 或 ] 结尾的止;紧凑排版的 JSON 中间也可能有以 ] 开头的行
  awk '!s && /^[[{]/ {s=1} s {buf[++n]=$0; if ($0 ~ /[]}][[:space:]]*$/) last=n} END {for (i=1; i<=last; i++) print buf[i]}'
}

# $thread = 正在读的 thread 的父消息 ts(读会话历史时为空)。
# 是不是回复:读 thread 时看 ts 是否等于父消息 ts —— 不依赖消息体里有没有 thread_ts 字段
# (0.7 的输出就没有);读会话历史时看 thread_ts。
NORMALIZE_JQ='
  ( [ (.users // [])[] | {key: .id, value: (.real_name // .name)} ] | from_entries ) as $names
  | [ .messages[]
      | select(.user != $self
               or (($mark != "" or $markre != "")
                   and ((.text // "") as $t
                        | (($mark != "" and ($t | startswith($mark)))
                           or ($markre != "" and ($t | test($markre))))
                        | not)))
      | select(.bot_id == null)
      # 滤掉 join/leave/pin 这类系统消息;「同时发到频道」的回复和带文件的消息是人发的,留着
      | select((.subtype // "") as $st | $st == "" or $st == "thread_broadcast" or $st == "file_share")
      | (if $thread != "" then $thread else (.thread_ts // .ts) end) as $root
      | select(($toponly | not) or $root == .ts)
      | {id: .ts,
         who: (.user_name // $names[.user // ""] // .user),
         at: .ts,
         kind: (if $root == .ts then "slack-message" else "slack-reply" end),
         thread_ts: (if $root == .ts then null else $root end),
         body: (.text // "")[0:$max]}
    ] | sort_by(.at)'

normalize() {  # stdin = 一页原始 JSON;$1=thread ts(可空) $2=toponly(true/false)
  jq -c --arg self "$SELF" --arg mark "$MARK" --arg markre "$MARKRE" --argjson max "$BODY_MAX" \
        --arg thread "$1" --argjson toponly "$2" "$NORMALIZE_JQ"
}

# 读一个会话(thread 为空)或一条 thread,按需翻页。
# $1=thread ts(空 = 会话历史) $2=起始 oldest(空 = 不限) $3=toponly
# 成功:结果数组放 OUT,return 0
# 失败:return 3(原因已打到 stderr);thread 第一页就失败时 return 4,调用方决定要不要试旧 CLI
OUT='[]'
read_pages() {
  local thr="$1" oldest="$2" toponly="$3" pages=0 raw rc count more next items acc='[]'
  local args
  while :; do
    pages=$((pages + 1))
    if [ "$pages" -gt "$MAX_PAGES" ]; then
      echo "翻满 MAX_PAGES=$MAX_PAGES 页仍未到底 —— 拒绝返回不完整结果,游标保持不动。调大 LIMIT/MAX_PAGES 后重试" >&2
      return 3
    fi
    args=(conversations read "$CHANNEL" --limit "$LIMIT" --json)
    [ -n "$thr" ] && args+=(--thread-ts "$thr")
    [ -n "$oldest" ] && args+=(--oldest "$oldest")
    raw=$(fetch_with_retry "$TIMEOUT" slackcli "${args[@]}" 2>/dev/null | json_only); rc=$?
    if [ $rc -ne 0 ] || [ -z "$raw" ]; then
      [ -n "$thr" ] && [ "$pages" -eq 1 ] && return 4
      echo "slackcli 拉取失败或超时(rc=$rc,第 $pages 页${thr:+,thread $thr})—— 拒绝返回不完整结果,游标保持不动" >&2
      echo "手跑一次确认子命令与输出结构:slackcli conversations read $CHANNEL ${thr:+--thread-ts $thr }--limit 5 --json" >&2
      return 3
    fi
    count=$(printf '%s' "$raw" | jq '.messages | length') \
      || { echo "slackcli 输出结构不符合预期,先手跑一次确认字段名" >&2; return 3; }
    more=$(printf '%s' "$raw" | jq -r '.has_more // false')
    items=$(printf '%s' "$raw" | normalize "$thr" "$toponly") \
      || { echo "slackcli 输出结构不符合预期,先手跑一次确认字段名" >&2; return 3; }
    acc=$(printf '%s\n%s' "$acc" "$items" | jq -cs 'add')   # 走 stdin,别走 argv(大 thread 会撑爆参数上限)
    next=$(printf '%s' "$raw" | jq -r '[.messages[].ts] | max // empty')
    # 会话历史没游标时这一页就是最新一页,再往后翻只会是空 —— 直接收工
    [ -z "$thr" ] && [ -z "$oldest" ] && break
    [ "$count" -lt "$LIMIT" ] && [ "$more" != "true" ] && break     # 不满一页且没有更多 = 到底了
    if [ -z "$next" ] || [ "$next" = "$oldest" ]; then              # oldest 推不动
      if [ "$more" = "true" ]; then
        echo "has_more=true 但 oldest 推不动(${thr:+thread $thr,}oldest=$oldest)—— 拒绝返回不完整结果" >&2
        return 3
      fi
      break
    fi
    oldest="$next"
  done
  OUT="$acc"
  return 0
}

# 0.7 及更早只有 `messages --channel --thread`:单次取,无法翻页 —— 取满即视为可能截断,fail closed
read_thread_legacy() {  # $1=thread ts;成功放 OUT
  local thr="$1" raw rc count
  raw=$(fetch_with_retry "$TIMEOUT" slackcli messages \
          --channel "$CHANNEL" --thread "$thr" --json 2>/dev/null | json_only); rc=$?
  if [ $rc -ne 0 ] || [ -z "$raw" ]; then
    echo "slackcli 拉取失败或超时(rc=$rc): $CHANNEL/$thr" >&2
    echo "手跑一次确认子命令与输出结构:slackcli conversations read $CHANNEL --thread-ts $thr --json" >&2
    return 3
  fi
  count=$(printf '%s' "$raw" | jq '.messages | length') \
    || { echo "slackcli 输出结构不符合预期,先手跑一次确认字段名" >&2; return 3; }
  if [ "$count" -ge "$LIMIT" ]; then
    echo "旧版 slackcli 不支持翻页,本次返回已达 LIMIT=$LIMIT 条,无法确认读完 —— 拒绝返回不完整结果,游标保持不动。升级 slackcli 或调大 LIMIT" >&2
    return 3
  fi
  OUT=$(printf '%s' "$raw" | normalize "$thr" false) \
    || { echo "slackcli 输出结构不符合预期,先手跑一次确认字段名" >&2; return 3; }
}

read_thread() {  # $1=thread ts $2=oldest;成功放 OUT
  read_pages "$1" "$2" false; local rc=$?
  if [ $rc -eq 4 ]; then
    if [ "$MODE" = "thread" ]; then   # 只有 thread 模式支持 0.7;其它模式第一页失败就是失败
      read_thread_legacy "$1"; rc=$?
    else
      echo "拉 thread $1 失败 —— 拒绝返回不完整结果,游标保持不动" >&2
      echo "手跑一次确认:slackcli conversations read $CHANNEL --thread-ts $1 --limit 5 --json" >&2
      rc=3
    fi
  fi
  return $rc
}

# 只有整串都是 <10位以上整数>.<整数> 才是 Slack ts,才能当 --oldest 用。
# 必须用正则而不是 case 的 glob:glob 里 * 通吃,`[0-9]*.[0-9]*` 会把
# "2026-09-07T11:42:45.583859Z" 这种 ISO8601 也认成 ts(二合一模板把 at 归一成 ISO 之后
# 游标就是这个形状),喂给 slackcli --oldest 直接报错,probe 挂掉 → watch 静默死。
# 游标不是 ts 时退化为全量读取,完整性不受影响,只是不能按游标跳过 thread。
CUR=""
if [[ "${PROBE_CURSOR:-}" =~ ^[0-9]{10,}\.[0-9]+$ ]]; then
  CUR="$PROBE_CURSOR"
fi

# 快照时刻,只在 all-threads 用(见头注释)。必须在第一次读取之前取
SNAP="$(( $(date +%s) - SNAPSHOT_LAG )).999999"

WORK=$(mktemp -d) || exit 3
trap 'rm -rf "$WORK"' EXIT
add_items() { printf '%s\n' "$1" >> "$WORK/items"; }   # 每行一个数组,最后 jq -s 合并

# ---------- thread 模式 ----------
if [ "$MODE" = "thread" ]; then
  read_thread "$THREAD_TS" "$CUR" || exit 3
  add_items "$OUT"
else
  # ---------- 顶层(top-level / all-threads 共用) ----------
  toponly=false; [ "$MODE" = "top-level" ] && toponly=true
  read_pages "" "$CUR" "$toponly" || exit 3
  add_items "$OUT"

  # ---------- all-threads:再看最近 THREAD_SCAN 条顶层消息底下的 thread ----------
  if [ "$MODE" = "all-threads" ]; then
    scan=$(fetch_with_retry "$TIMEOUT" slackcli conversations read "$CHANNEL" --limit "$THREAD_SCAN" --json 2>/dev/null | json_only); rc=$?
    if [ $rc -ne 0 ] || [ -z "$scan" ]; then
      echo "扫 thread 列表失败(rc=$rc)—— 拒绝返回不完整结果,游标保持不动" >&2
      exit 3
    fi
    parents=$(printf '%s' "$scan" | jq -c '
      [ .messages[] | select((.reply_count // 0) > 0)
        | {ts, n: .reply_count, latest: (.latest_reply // null)} ]') \
      || { echo "slackcli 输出结构不符合预期(扫 thread 列表),先手跑一次确认字段名" >&2; exit 3; }

    # 缓存:{ "<父消息 ts>": {n: reply_count, last: 会叫醒你的回复的 ts 上界, stable: 这个 n 是否已连续拉到两次} }
    # 「会叫醒你」取决于过滤规则,所以文件名里带 SELF / AGENT_MARK / AGENT_MARK_RE 的摘要
    cache_dir="${THREAD_CACHE_DIR:-${TMPDIR:-/tmp}/incremental-watch-slack}"
    fkey=$(printf '%s|%s|%s' "$SELF" "$MARK" "$MARKRE" | cksum | cut -d' ' -f1)
    cache_file="$cache_dir/threads-${CHANNEL//[^A-Za-z0-9_-]/_}-$fkey.json"
    # 坏掉的条目一律丢掉(当没缓存,多拉而已),不能让它把整个计划搞崩
    cache=$(jq -c 'if type == "object" then with_entries(select(.value | type == "object"
                     and (.n | type) == "number" and (.last | type) == "string" and (.stable | type) == "boolean"))
                   else {} end' "$cache_file" 2>/dev/null)
    [ -n "$cache" ] || cache='{}'

    # 每个 thread 决定拉还是跳。没有 ts 游标(seed / ISO 游标)时一律拉
    plan=$(jq -cn --argjson p "$parents" --argjson c "$cache" --arg cur "$CUR" '
      [ $p[] | . as $x | ($c[$x.ts] // null) as $e
        | if $cur == "" then $x + {fetch: true, prev: $e}
          elif $x.latest != null and $x.latest <= $cur then $x + {fetch: false, keep: {n: $x.n, last: $x.latest, stable: true}}
          elif $e != null and $e.n == $x.n and $e.stable and $e.last <= $cur then $x + {fetch: false, keep: $e}
          else $x + {fetch: true, prev: $e} end ]') \
      || { echo "排 thread 拉取计划失败 —— 拒绝返回不完整结果" >&2; exit 3; }

    : > "$WORK/cache"
    while IFS=$'\t' read -r pts pn fetch keep prev_n; do
      [ -n "$pts" ] || continue
      if [ "$fetch" = "true" ]; then
        read_thread "$pts" "$CUR" || exit 3
        add_items "$OUT"
        # 拉到底了:会叫醒你的回复,ts 都 <= max(本次拿到的最大 ts, oldest)
        last=$(printf '%s' "$OUT" | jq -r 'map(.at) | max // ""')
        if [ -n "$CUR" ] && { [ -z "$last" ] || [[ "$CUR" > "$last" ]]; }; then last="$CUR"; fi
        stable=false; [ "$prev_n" = "$pn" ] && stable=true
        keep=$(jq -cn --argjson n "$pn" --arg last "$last" --argjson st "$stable" '{n: $n, last: $last, stable: $st}')
      fi
      printf '%s\t%s\n' "$pts" "$keep" >> "$WORK/cache"
    done < <(printf '%s' "$plan" | jq -r '.[] | [.ts, (.n|tostring), (.fetch|tostring), ((.keep // {})|tojson), ((.prev.n // "")|tostring)] | @tsv')

    # 只留这次扫到的 thread,文件大小有上界。写不了就算了,下一轮多拉几次而已
    if mkdir -p "$cache_dir" 2>/dev/null; then
      tmp="$cache_file.$$"
      jq -Rn '[inputs | split("\t") | {key: .[0], value: (.[1] | fromjson)}] | from_entries' "$WORK/cache" > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$cache_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    fi
  fi
fi

ITEMS=$(jq -cs 'add // [] | unique_by(.id) | sort_by(.at)' "$WORK/items") \
  || { echo "合并结果失败" >&2; exit 3; }

# all-threads:晚于快照的这一轮先不交(见头注释),下一轮再给
if [ "$MODE" = "all-threads" ]; then
  ITEMS=$(printf '%s' "$ITEMS" | jq -c --argjson snap "$SNAP" 'map(select((.at | tonumber) <= $snap))')
fi


if [ -n "$TERMINATE_RE" ]; then
  ITEMS=$(printf '%s' "$ITEMS" | jq -c --arg re "$TERMINATE_RE" '
    map(if (.body | test($re; "i")) then . + {kind:"terminal", reason:"命中 TERMINATE_RE"} else . end)')
fi

printf '%s' "$ITEMS"
