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
# **本模板不分页。** GitHub 侧每个 endpoint 都带 --paginate,这里只取一次。thread 长到
# 超过 LIMIT 时会静默截断 —— 更长的 thread 请照着 slackcli 的分页参数自己改写。

set -uo pipefail
. "$(dirname "$0")/_lib.sh"
require_bin slackcli jq
SELF="${SLACK_SELF:-${SELF:-}}"
require_env CHANNEL THREAD_TS SELF

TIMEOUT="${TIMEOUT:-25}"
BODY_MAX="${BODY_MAX:-280}"
LIMIT="${LIMIT:-100}"
TERMINATE_RE="${TERMINATE_RE:-}"

json_only() { sed -n '/^[[{]/,$p'; }

# 新版(0.9+)
RAW=$(run_with_timeout "$TIMEOUT" slackcli conversations read "$CHANNEL" \
        --thread-ts "$THREAD_TS" --limit "$LIMIT" --json 2>/dev/null | json_only)
rc=$?

# 旧版(0.7 及更早)
if [ $rc -ne 0 ] || [ -z "$RAW" ]; then
  RAW=$(run_with_timeout "$TIMEOUT" slackcli messages \
          --channel "$CHANNEL" --thread "$THREAD_TS" --json 2>/dev/null | json_only)
  rc=$?
fi

if [ $rc -ne 0 ] || [ -z "$RAW" ]; then
  echo "slackcli 拉取失败或超时(rc=$rc): $CHANNEL/$THREAD_TS" >&2
  echo "手跑一次确认子命令与输出结构:slackcli conversations read $CHANNEL --thread-ts $THREAD_TS --json" >&2
  exit 3
fi

ITEMS=$(printf '%s' "$RAW" | jq -c --arg self "$SELF" --argjson max "$BODY_MAX" '
  ( [ (.users // [])[] | {key: .id, value: (.real_name // .name)} ] | from_entries ) as $names
  | [ .messages[]
      | select(.user != $self)
      | select(.bot_id == null)
      | select((.subtype // "") == "")          # 滤掉 join/leave/pin 这类系统消息
      | {id: .ts,
         who: (.user_name // $names[.user // ""] // .user),
         at: .ts,
         kind: "slack-reply",
         body: (.text // "")[0:$max]}
    ] | sort_by(.at)') || { echo "slackcli 输出结构不符合预期,先手跑一次确认字段名" >&2; exit 3; }

if [ -n "$TERMINATE_RE" ]; then
  ITEMS=$(printf '%s' "$ITEMS" | jq -c --arg re "$TERMINATE_RE" '
    map(if (.body | test($re; "i")) then . + {kind:"terminal", reason:"命中 TERMINATE_RE"} else . end)')
fi

printf '%s' "$ITEMS"
