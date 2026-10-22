#!/bin/bash
# 盯一个 Slack 频道 / DM 里的新消息(不限于某条 thread)。
#
# 跟 probe-slack-thread.sh 的关系:同一套形状,少一个维度。
#   thread 版  —— 只看 THREAD_TS 那条 thread 底下的回复
#   channel 版 —— 看整个会话,包括没有开 thread 的顶层消息
# 选哪个看 SKILL.md 的表。**DM 一律用这个版本**:私聊里大家习惯直接回,不开 thread,
# 用 thread 版盯自己那条消息的 thread_ts 会永远报「无变化」。
# (2026-09-22 真踩过:给同事发 DM 问问题,对方直接在 DM 里回,watch 一直安静,
#  最后是人来提醒才发现的。)
#
# 用 slackcli(https://github.com/shaharia-lab/slackcli,开源,输出 JSON)。
# 换成直接打 Slack Web API 的 conversations.history 也行,只要最后吐出同样形状的数组。
#
# 配置(环境变量):
#   CHANNEL     必需  频道 ID(C...)、私聊 channel ID(D...)或群聊(G.../mpim)
#                     注意是 **channel ID**,不是对方的 user ID(U...)。
#                     D 开头的 ID 用 `slackcli conversations list --types im` 查
#   SELF        必需  你自己的 Slack user ID(U...)。不填会被自己的消息叫醒,死循环
#               也可以用 SLACK_SELF —— 跟 GitHub 模板同时用时用它,免得两边互相覆盖
#   TIMEOUT     可选  超时秒数,默认 25
#   BODY_MAX    可选  正文截断长度,默认 280
#   LIMIT       可选  一次取多少条,默认 100
#   MAX_PAGES   可选  最多翻几页,默认 20
#   EXCLUDE_REPLIES 可选  =1 时只要顶层消息,thread 里的回复不算(本模板自己滤,
#                     不用 CLI 的 --exclude-replies,原因见下面翻页那段)。
#                     默认**要**回复 —— 顶层和 thread 里回都能叫醒你,这正是本模板的意义
#   TERMINATE_RE 可选 正则;某条消息命中就报 terminal(比如 '结了|closed|done')
#
# 用法:
#   export CHANNEL=D0XXXXXXXXX SELF=U0XXXXXXXXX
#   scripts/watch-loop.sh --name dm-x --probe scripts/templates/probe-slack-channel.sh --seed
#   scripts/watch-loop.sh --name dm-x --probe scripts/templates/probe-slack-channel.sh --interval 180
#
# 游标:Slack 的 ts 是字符串化时间戳,字典序 == 时间序(2001 年之后都是 10 位整数部分),
# 直接当游标用。thread 版也是这个游标,两个模板可以互换而不用重新 seed。
#
# 关于「取满一页」这件事,两条实测结论,别混:
#   1. 不带 --oldest 时,截断丢的是**最旧**的消息 —— Slack 返回的是最近 N 条。
#      所以就算一页装不下,最新的消息一定在里面,ts 游标不会漏唤醒。
#   2. **绝不能拿消息条数做变化检测。** slackcli 默认一页 100 条,长会话的返回条数
#      恒定顶在上限(thread 版是 parent + 100 回复 = 101),条数永远不变,
#      watch 会一直报「没新消息」。判断变化只看 ts,不看 count。
# 下面的翻页只用来保证「这一轮的新消息全都取到了」,不用来做变化检测。
#
# 分页分两种情况,因为「有没有 --oldest」会改变 Slack 返回哪一段(实测,别想当然):
#   不带 --oldest  → 返回**最新** LIMIT 条(所以截断丢的是最旧的)
#   带   --oldest  → 返回该时刻**之后**的 LIMIT 条,oldest 本身不含(所以能往前推着翻)
# 于是:
#   有游标(稳态,每轮都是这条路):把 PROBE_CURSOR 当 oldest,取满一页(count == LIMIT)
#     就把 oldest 推到本页最大 ts 再取,直到不满一页为止,跨页去重靠 ts 唯一。这条路是
#     完整的 —— 游标之后的消息一条不漏。翻满 MAX_PAGES 仍不到底、或翻页中途失败,probe
#     整体失败(exit 3),游标保持不动 —— 宁可叫醒 agent,也不静默截断丢事件。
#   没游标(只出现在 --seed,或者你忘了 seed):只取最新一页,不往回翻。seed 要的只是
#     「最新那条的 ts」,而截断丢的是最旧的,最新那条一定在里面,所以游标对得上。
#     代价是:**不 seed 直接起循环的话,首轮最多只看到最近 LIMIT 条**,更早的历史不会进
#     inbox。按流程先 --seed 就没这回事。
# 早先这里对两种情况用同一套前向翻页,结果没游标时第一页拿到的是最新 LIMIT 条、再往
# 后翻必然是空,等于静默只取一页 —— 所以这两条路必须分开写。
#
# 另外:EXCLUDE_REPLIES 是本模板自己在 jq 里滤的,**没有**用 CLI 的 --exclude-replies。
# 因为那个 flag 是拿到一页之后在本地筛的,返回条数会变成「筛剩下的」(实测同一段区间
# 100 → 65),于是「不满一页 = 到底了」这个翻页判据直接失真:65 < LIMIT 就停了,后面
# 真实存在的消息一条都没取。翻页只能按 CLI 返回的原始条数判断,过滤放到之后做。
#
# CLI 会把进度行("- Fetching messages...")打到 stdout,JSON 从第一个 { 开始;
# 偶尔还会在 JSON **后面**追一段 "Update available: ..." 的升级提示。所以下面的
# json_only 是一个**有头有尾**的范围,只留从第一个 { 到第一个顶格 } 的部分 ——
# 只掐头不掐尾的话,那段升级提示会把 jq 直接搞崩(它不是每次都出现,所以这种崩
# 是偶发的,更难查)。

set -uo pipefail
. "$(dirname "$0")/_lib.sh"
require_bin slackcli jq
SELF="${SLACK_SELF:-${SELF:-}}"
require_env CHANNEL SELF

# 本模板的读取与过滤行为依赖 slackcli 的输出契约,只在 0.9.x 上验证过
# (0.9 的 `conversations read <channel>` 不带 --thread-ts 就是读整个会话)。
# 0.7 的 `messages` 子命令读频道这条路没验证过,所以这里不做回退。
# 其它版本 fail closed:确认过输出结构没变后,用 SLACKCLI_ALLOW_UNTESTED=1 放行。
ver=$(slackcli --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
case "$ver" in
  0.9.*|0.9) : ;;
  *) [ "${SLACKCLI_ALLOW_UNTESTED:-0}" = "1" ] \
       || { echo "未验证的 slackcli 版本 '$ver'(本模板已验证 0.9.x)。手跑一次确认 JSON 输出结构后,用 SLACKCLI_ALLOW_UNTESTED=1 放行" >&2; exit 2; } ;;
esac

TIMEOUT="${TIMEOUT:-25}"
BODY_MAX="${BODY_MAX:-280}"
LIMIT="${LIMIT:-100}"
MAX_PAGES="${MAX_PAGES:-20}"
TERMINATE_RE="${TERMINATE_RE:-}"
case "${EXCLUDE_REPLIES:-0}" in
  1|true|yes) NOREPLIES=true ;;
  0|''|false|no) NOREPLIES=false ;;
  *) echo "EXCLUDE_REPLIES 只接受 0/1,收到: '${EXCLUDE_REPLIES}'" >&2; exit 3 ;;
esac

json_only() {  # 从第一行 { 或 [ 开头的起,到最后一行以 } 或 ] 结尾的止;紧凑排版的 JSON 中间也可能有以 ] 开头的行
  awk '!s && /^[[{]/ {s=1} s {buf[++n]=$0; if ($0 ~ /[]}][[:space:]]*$/) last=n} END {for (i=1; i<=last; i++) print buf[i]}'
}

# 数值配置必须先校验:非数字的 MAX_PAGES 会让 -gt 比较每轮报错返回假,翻页上限静默失效,
# fail-closed 路径整个绕过;LIMIT 非数字则「取满一页」的判断同样失真。启动前挡住,exit 3
for pair in "MAX_PAGES:$MAX_PAGES" "LIMIT:$LIMIT" "TIMEOUT:$TIMEOUT" "BODY_MAX:$BODY_MAX"; do
  name=${pair%%:*}; val=${pair#*:}
  case "$val" in
    ''|*[!0-9]*) echo "$name 必须是正整数,收到: '$val'" >&2; exit 3 ;;
    0) [ "$name" = "BODY_MAX" ] || { echo "$name 不能是 0" >&2; exit 3; } ;;
  esac
done

# 形状跟 probe-slack-thread.sh 一致(id/who/at/kind/body),多一个 thread_ts:
# 醒来要回消息时,顶层消息和 thread 里的回复回法不同,这个字段告诉你回哪儿
# (null = 顶层)。kind 用 slack-message 区别于 thread 版的 slack-reply。
NORMALIZE_JQ='
  ( [ (.users // [])[] | {key: .id, value: (.real_name // .name)} ] | from_entries ) as $names
  | [ .messages[]
      | select(.user != $self or ((env.SELF_KEEP_HUMAN // "") == "1" and (((.text // "") | test("^\\[ (:dog:|🐶) Claude:\\]")) | not)))   # 和人共用账号时：SELF_KEEP_HUMAN=1 只滤带 Claude 前缀的
      | select(.bot_id == null)
      | select((.subtype // "") == "")          # 滤掉 join/leave/pin 这类系统消息
      | select(($noreplies | not) or ((.thread_ts // .ts) == .ts))
      | {id: .ts,
         who: (.user_name // $names[.user // ""] // .user),
         at: .ts,
         kind: "slack-message",
         thread_ts: (if (.thread_ts // .ts) == .ts then null else .thread_ts end),
         body: (.text // "")[0:$max]}
    ] | sort_by(.at)'

page_read() {  # $1=oldest(空 = 不限);stdout = 本页原始 JSON
  local args=(conversations read "$CHANNEL" --limit "$LIMIT" --json)
  [ -n "$1" ] && args+=(--oldest "$1")
  fetch_with_retry "$TIMEOUT" slackcli "${args[@]}" 2>/dev/null | json_only
}

oldest=""
# 只有整串都是 <10位以上整数>.<整数> 才是 Slack ts,才能当 --oldest 用。
# 这里必须用正则而不是 case 的 glob:glob 里 * 通吃,`[0-9]*.[0-9]*` 会把
# "2026-09-07T11:42:45.583859Z" 这种 ISO8601 也认成 ts,喂给 slackcli --oldest
# 直接报错,probe 挂掉 → watch 静默死。
if [[ "${PROBE_CURSOR:-}" =~ ^[0-9]{10,}\.[0-9]+$ ]]; then
  oldest="$PROBE_CURSOR"
fi

PAGES='[]'; pages=0
while :; do
  pages=$((pages + 1))
  if [ "$pages" -gt "$MAX_PAGES" ]; then
    echo "翻满 MAX_PAGES=$MAX_PAGES 页仍未到底 —— 拒绝返回不完整结果,游标保持不动。调大 LIMIT/MAX_PAGES 后重试" >&2
    exit 3
  fi
  RAW=$(page_read "$oldest"); rc=$?
  if [ $rc -ne 0 ] || [ -z "$RAW" ]; then
    echo "slackcli 拉取失败或超时(rc=$rc,第 $pages 页)—— 拒绝返回不完整结果,游标保持不动" >&2
    echo "手跑一次确认子命令与输出结构:slackcli conversations read $CHANNEL --limit 5 --json" >&2
    exit 3
  fi
  count=$(printf '%s' "$RAW" | jq '.messages | length') \
    || { echo "slackcli 输出结构不符合预期,先手跑一次确认字段名" >&2; exit 3; }
  page_items=$(printf '%s' "$RAW" | jq -c --arg self "$SELF" --argjson max "$BODY_MAX" \
                 --argjson noreplies "$NOREPLIES" "$NORMALIZE_JQ") \
    || { echo "slackcli 输出结构不符合预期,先手跑一次确认字段名" >&2; exit 3; }
  PAGES=$(jq -cn --argjson a "$PAGES" --argjson b "$page_items" '$a + $b')
  # 没有游标时这一页就是最新一页,再往后翻只会是空 —— 直接收工,别假装翻完了
  [ -n "$oldest" ] || break
  [ "$count" -lt "$LIMIT" ] && break              # 不满一页 = 到底了
  next=$(printf '%s' "$RAW" | jq -r '[.messages[].ts] | max // empty')
  [ -n "$next" ] || break
  [ "$next" = "$oldest" ] && break                # oldest 不前进就停,防 inclusive 语义死循环
  oldest="$next"
done

ITEMS=$(printf '%s' "$PAGES" | jq -c 'unique_by(.id) | sort_by(.at)')

if [ -n "$TERMINATE_RE" ]; then
  ITEMS=$(printf '%s' "$ITEMS" | jq -c --arg re "$TERMINATE_RE" '
    map(if (.body | test($re; "i")) then . + {kind:"terminal", reason:"命中 TERMINATE_RE"} else . end)')
fi

printf '%s' "$ITEMS"
