#!/bin/bash
# 盯一条 Slack thread 的回复。
#
# 用 slackcli(https://github.com/shaharia-lab/slackcli,开源,输出 JSON)。
# 换成直接打 Slack Web API 的 conversations.replies 也行,只要最后吐出同样形状的数组。
#
# 配置(环境变量):
#   CHANNEL     必需  频道 ID,如 C0XXXXXXXXX
#   THREAD_TS   必需  父消息的 ts,如 1700000000.000000
#   SELF        必需  你自己的 Slack user ID(U...)。不填会被自己的回复叫醒,死循环
#               也可以用 SLACK_SELF —— 跟 GitHub 模板同时用时用它,免得两边互相覆盖
#   TIMEOUT     可选  超时秒数,默认 25
#   BODY_MAX    可选  正文截断长度,默认 280
#   LIMIT       可选  一次取多少条,默认 100
#   TERMINATE_RE 可选 正则;某条回复命中就报 terminal(比如 '结了|closed|done')
#
# 用法:
#   export CHANNEL=C0XXXXXXXXX THREAD_TS=1700000000.000000 SELF=U0XXXXXXXXX
#   scripts/watch-loop.sh --name thr-x --probe scripts/templates/probe-slack-thread.sh --seed
#   scripts/watch-loop.sh --name thr-x --probe scripts/templates/probe-slack-thread.sh --interval 180
#
# 注意:Slack 的 ts 是字符串化时间戳,字典序 == 时间序(2001 年之后都是 10 位整数部分),
# 所以可以直接当游标。
#
# 两种 slackcli 子命令都支持:0.7 及更早是 `messages --channel --thread`,0.9 起改成
# `conversations read <channel> --thread-ts`。先试新的,失败再试旧的,所以升级 CLI
# 不用改这个文件。两种输出结构也不同,jq 那段做了归一:
#   0.9  {message_count, messages:[{ts,user,text,...}], users:[{id,real_name,email}]}
#   0.7  {messages:[{ts,user,user_name,text,...}]}
# 0.9 的消息体里只有 user id,人名在顶层 users[] 里,要按 id 关联;关联不上就退回 id。
#
# CLI 会把进度行("- Fetching messages...")打到 stdout,JSON 从第一个 { 开始,所以下面
# 先用 sed 掐掉前面的非 JSON 行。
#
# 分页:0.9 的 conversations read 没有 cursor 翻页,但有 --oldest(时间下界),而 Slack ts
# 在同一 thread 内严格递增 —— 取满一页(count == LIMIT)就把 oldest 推到本页最大 ts 再取,
# 直到不满一页为止,跨页去重靠 ts 唯一。翻满 MAX_PAGES(默认 20)仍不到底、或翻页中途失败,
# probe 整体失败(exit 3),游标保持不动 —— 宁可叫醒 agent,也不静默截断丢事件。
# PROBE_CURSOR 长得像 Slack ts 时用作起始 oldest(单独使用本模板时如此);二合一模板把 at
# 归一成了 ISO8601,那种场合退化为全量翻页,完整性不受影响。
# 旧版(0.7)的 messages 子命令不支持 --oldest/--limit 翻页:返回条数达到 LIMIT 时同样
# fail closed,提示升级或调大 LIMIT。

set -uo pipefail
. "$(dirname "$0")/_lib.sh"
require_bin slackcli jq
SELF="${SLACK_SELF:-${SELF:-}}"
require_env CHANNEL THREAD_TS SELF

# 本模板的读取与过滤行为依赖 slackcli 的输出契约,只在 0.7.x 和 0.9.x 上验证过。
# 其它版本 fail closed:确认过输出结构没变后,用 SLACKCLI_ALLOW_UNTESTED=1 放行。
# (jq 那段解析失败本来也会 exit 3,这里是把「版本变了」显式挡在更前面。)
ver=$(slackcli --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
case "$ver" in
  0.7.*|0.7|0.9.*|0.9) : ;;
  *) [ "${SLACKCLI_ALLOW_UNTESTED:-0}" = "1" ] \
       || { echo "未验证的 slackcli 版本 '$ver'(已验证 0.7.x / 0.9.x)。手跑一次确认 JSON 输出结构后,用 SLACKCLI_ALLOW_UNTESTED=1 放行" >&2; exit 2; } ;;
esac

TIMEOUT="${TIMEOUT:-25}"
BODY_MAX="${BODY_MAX:-280}"
LIMIT="${LIMIT:-100}"
TERMINATE_RE="${TERMINATE_RE:-}"

# 掐头也要掐尾:CLI 偶尔会在 JSON 后面追一段 "Update available: ..." 的升级提示,
# 只掐头的话那段会把 jq 搞崩(不是每次都出现,所以是偶发崩)。
json_only() { sed -n '/^[[{]/,/^[]}]/p'; }

MAX_PAGES="${MAX_PAGES:-20}"

# 数值配置必须先校验:非数字的 MAX_PAGES 会让 -gt 比较每轮报错返回假,翻页上限静默失效,
# fail-closed 路径整个绕过;LIMIT 非数字则「取满一页」的判断同样失真。启动前挡住,exit 3
for pair in "MAX_PAGES:$MAX_PAGES" "LIMIT:$LIMIT" "TIMEOUT:$TIMEOUT" "BODY_MAX:$BODY_MAX"; do
  name=${pair%%:*}; val=${pair#*:}
  case "$val" in
    ''|*[!0-9]*) echo "$name 必须是正整数,收到: '$val'" >&2; exit 3 ;;
    0) [ "$name" = "BODY_MAX" ] || { echo "$name 不能是 0" >&2; exit 3; } ;;
  esac
done

NORMALIZE_JQ='
  ( [ (.users // [])[] | {key: .id, value: (.real_name // .name)} ] | from_entries ) as $names
  | [ .messages[]
      # 自过滤按「代发前缀」而不是按 user id：这条 thread 是用 Victor 的账号发的，
      # 按 user id 滤会把 Victor 本人的回复也一起滤掉。
      | select((.text // "") | startswith("[ :dog: Claude:]") | not)
      | select(.bot_id == null)
      | select((.subtype // "") == "")          # 滤掉 join/leave/pin 这类系统消息
      | {id: .ts,
         who: (.user_name // $names[.user // ""] // .user),
         at: .ts,
         kind: "slack-reply",
         body: (.text // "")[0:$max]}
    ] | sort_by(.at)'

page_read() {  # $1=oldest(空 = 不限);stdout = 本页原始 JSON
  local args=(conversations read "$CHANNEL" --thread-ts "$THREAD_TS" --limit "$LIMIT" --json)
  [ -n "$1" ] && args+=(--oldest "$1")
  fetch_with_retry "$TIMEOUT" slackcli "${args[@]}" 2>/dev/null | json_only
}

oldest=""
# 只有整串都是 <10位以上整数>.<整数> 才是 Slack ts,才能当 --oldest 用。
# 这里必须用正则而不是 case 的 glob:glob 里 * 通吃,`[0-9]*.[0-9]*` 会把
# "2026-09-07T11:42:45.583859Z" 这种 ISO8601 也认成 ts(二合一模板把 at 归一成 ISO
# 之后游标就是这个形状),喂给 slackcli --oldest 直接报错,probe 挂掉 → watch 静默死。
if [[ "${PROBE_CURSOR:-}" =~ ^[0-9]{10,}\.[0-9]+$ ]]; then
  oldest="$PROBE_CURSOR"
fi

PAGES='[]'; pages=0; newmode=1
while :; do
  pages=$((pages + 1))
  if [ "$pages" -gt "$MAX_PAGES" ]; then
    echo "翻满 MAX_PAGES=$MAX_PAGES 页仍未到底 —— 拒绝返回不完整结果,游标保持不动。调大 LIMIT/MAX_PAGES 后重试" >&2
    exit 3
  fi
  RAW=$(page_read "$oldest"); rc=$?
  if [ $rc -ne 0 ] || [ -z "$RAW" ]; then
    [ "$pages" -eq 1 ] && { newmode=0; break; }   # 第一页就失败 → 试旧版子命令
    echo "翻页中途 slackcli 失败(rc=$rc,第 $pages 页)—— 拒绝返回不完整结果,游标保持不动" >&2
    exit 3
  fi
  count=$(printf '%s' "$RAW" | jq '.messages | length') \
    || { echo "slackcli 输出结构不符合预期,先手跑一次确认字段名" >&2; exit 3; }
  page_items=$(printf '%s' "$RAW" | jq -c --arg self "$SELF" --argjson max "$BODY_MAX" "$NORMALIZE_JQ") \
    || { echo "slackcli 输出结构不符合预期,先手跑一次确认字段名" >&2; exit 3; }
  PAGES=$(jq -cn --argjson a "$PAGES" --argjson b "$page_items" '$a + $b')
  [ "$count" -lt "$LIMIT" ] && break              # 不满一页 = 到底了
  next=$(printf '%s' "$RAW" | jq -r '[.messages[].ts] | max // empty')
  [ -n "$next" ] || break
  [ "$next" = "$oldest" ] && break                # oldest 不前进就停,防 inclusive 语义死循环
  oldest="$next"
done

# 旧版(0.7 及更早):单次取,无法翻页 —— 取满即视为可能截断,fail closed
if [ "$newmode" = "0" ]; then
  RAW=$(fetch_with_retry "$TIMEOUT" slackcli messages \
          --channel "$CHANNEL" --thread "$THREAD_TS" --json 2>/dev/null | json_only)
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$RAW" ]; then
    echo "slackcli 拉取失败或超时(rc=$rc): $CHANNEL/$THREAD_TS" >&2
    echo "手跑一次确认子命令与输出结构:slackcli conversations read $CHANNEL --thread-ts $THREAD_TS --json" >&2
    exit 3
  fi
  count=$(printf '%s' "$RAW" | jq '.messages | length') \
    || { echo "slackcli 输出结构不符合预期,先手跑一次确认字段名" >&2; exit 3; }
  if [ "$count" -ge "$LIMIT" ]; then
    echo "旧版 slackcli 不支持翻页,本次返回已达 LIMIT=$LIMIT 条,无法确认读完 —— 拒绝返回不完整结果,游标保持不动。升级 slackcli 或调大 LIMIT" >&2
    exit 3
  fi
  PAGES=$(printf '%s' "$RAW" | jq -c --arg self "$SELF" --argjson max "$BODY_MAX" "$NORMALIZE_JQ") \
    || { echo "slackcli 输出结构不符合预期,先手跑一次确认字段名" >&2; exit 3; }
fi

ITEMS=$(printf '%s' "$PAGES" | jq -c 'unique_by(.id) | sort_by(.at)')

if [ -n "$TERMINATE_RE" ]; then
  ITEMS=$(printf '%s' "$ITEMS" | jq -c --arg re "$TERMINATE_RE" '
    map(if (.body | test($re; "i")) then . + {kind:"terminal", reason:"命中 TERMINATE_RE"} else . end)')
fi

printf '%s' "$ITEMS"
