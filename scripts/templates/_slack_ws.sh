#!/bin/bash
# probe 这一侧的 WS 缓冲读取。被 probe-slack.sh source,不单独跑。
#
# 常驻的 scripts/slack-ws-daemon.mjs 把整个工作区的消息写进一个事件文件,这里负责
# 两件事:判断这一轮**敢不敢**信这个缓冲,敢就从文件里读出和轮询一模一样形状的数组。
#
# 不敢信就退回轮询,一共四种情况,每种都往 stderr 写一行(进 watch 的 log,方便事后看
# 到底省了多少轮):
#   1. daemon 不在、状态过期、或者会话失效 —— 缓冲根本不更新
#   2. 这个频道不在 daemon 的成员名单里 —— WS 只推你是成员的会话,而轮询用 user token
#      连没加入的公共频道也读得到。不比对的话,盯这种频道就是「daemon 一切正常 + 一条都
#      收不到」,每轮报「没有新消息」。名单在 daemon 的 channels.json,拿不到就一律轮询
#   3. 游标早于 covered_from —— 断线期间的消息网页版不补发,缓冲这段是空的,必须轮询补齐。
#      seed(没有游标)也走这里
#   4. 到了校验时刻 —— 见下
#
# 为什么还要定期轮询校验(SLACK_WS_VERIFY,默认 1800 秒):
# 「某个频道的帧根本没推过来」这种失效,缓冲自己是看不出来的 —— 它只会一直说「没有新消息」,
# 正是这套机制最怕的那种静默失败。所以每隔一段时间照常轮询一轮:省下的请求从 100% 降到
# 约 94%(30 分钟里只有一轮走接口),但漏消息的窗口被压到一个校验周期。
# 想要更省就调大 SLACK_WS_VERIFY,想更保守就调小。=0 是**关掉校验**、永远信缓冲 ——
# 只在你已经确认过这个频道的帧确实会推过来时才这么用。
#
# 配置:
#   SLACK_WS        1 = 开;0 / 不设 = 关(默认)。关着时这个文件里的函数一律不被调用
#   SLACK_WS_DIR    daemon 的状态目录,默认 ~/.claude/watch/_slack-ws
#   SLACK_WS_STALE  status.json 多久没更新就算 daemon 死了,默认 60 秒
#   SLACK_WS_VERIFY 多久强制轮询校验一轮,默认 1800 秒
#
# probe-pr-and-slack.sh 用不上 WS:它把两个源的时间戳归一成了 ISO8601,游标不是 Slack ts,
# 这里认不出来,每轮都会退回轮询。这是对的(宁可多打接口),只是别指望它省调用。

ws_dir() { printf '%s' "${SLACK_WS_DIR:-$HOME/.claude/watch/_slack-ws}"; }

ws_enabled() {
  case "${SLACK_WS:-0}" in
    1|true|yes) return 0 ;;
    0|''|false|no) return 1 ;;
    *) echo "SLACK_WS 只接受 0/1,收到: '${SLACK_WS}'" >&2; exit 3 ;;
  esac
}

# 这一轮能不能用缓冲。$1=游标(可空)。不能用时往 stderr 说明原因,return 1。
ws_can_serve() {
  local cur="$1" dir status now stale verify marker last
  dir=$(ws_dir); status="$dir/status.json"
  stale="${SLACK_WS_STALE:-60}"
  verify="${SLACK_WS_VERIFY:-1800}"
  case "$stale$verify" in *[!0-9]*) echo "SLACK_WS_STALE / SLACK_WS_VERIFY 必须是非负整数" >&2; exit 3 ;; esac

  [ -r "$status" ] || { echo "WS 缓冲:没有 $status,这轮走轮询(daemon 没起?)" >&2; return 1; }
  now=$(date +%s)

  # daemon 活着吗:状态要新鲜,而且确实连上了
  if ! jq -e --argjson now "$now" --argjson stale "$stale" '
        .state == "READY" and ((.updated_at | tonumber) > ($now - $stale))' "$status" >/dev/null 2>&1; then
    echo "WS 缓冲:daemon 状态不是新鲜的 READY($(jq -r '.state // "?"' "$status" 2>/dev/null)),这轮走轮询" >&2
    return 1
  fi

  # 这个频道 daemon 收得到吗。名单不存在 / 读不出来 / 频道不在里面,都走轮询
  if ! jq -e --arg ch "$CHANNEL" '(.ids // []) | index($ch) != null' "$dir/channels.json" >/dev/null 2>&1; then
    echo "WS 缓冲:$CHANNEL 不在 daemon 的成员名单里(或名单还没写出来),这轮走轮询" >&2
    return 1
  fi

  # 缓冲覆盖得住游标吗。没有游标(seed)一律轮询:seed 要的是「最新那条」,缓冲里不一定有
  [ -n "$cur" ] || { echo "WS 缓冲:没有 ts 游标(seed 或非 ts 游标),这轮走轮询" >&2; return 1; }
  if ! jq -e --arg cur "$cur" '
        (.covered_from // "") != "" and ((.covered_from | tonumber) <= ($cur | tonumber))' "$status" >/dev/null 2>&1; then
    echo "WS 缓冲:游标 $cur 早于 covered_from $(jq -r '.covered_from // "null"' "$status" 2>/dev/null),这轮轮询补齐" >&2
    return 1
  fi

  # 到校验时刻了吗。marker 按 频道+模式 一份,多个 watch 盯同一个频道时各自计时
  if [ "$verify" -gt 0 ]; then
    marker="${THREAD_CACHE_DIR:-${TMPDIR:-/tmp}/incremental-watch-slack}/ws-verify-${CHANNEL//[^A-Za-z0-9_-]/_}-${MODE}"
    last=0
    [ -f "$marker" ] && last=$(stat -f %m "$marker" 2>/dev/null || stat -c %Y "$marker" 2>/dev/null || echo 0)
    if [ $((now - last)) -ge "$verify" ]; then
      mkdir -p "$(dirname "$marker")" 2>/dev/null && : > "$marker" 2>/dev/null
      echo "WS 缓冲:到校验时刻(每 ${verify}s 一次),这轮走轮询对一遍" >&2
      return 1
    fi
  fi
  return 0
}

# 从缓冲里读出这个 watch 要的项,形状跟轮询完全一致。$1=游标
# 过滤规则跟 probe-slack.sh 的 NORMALIZE_JQ 一致:只滤 SELF 名下带 agent 前缀的、bot、系统消息。
# 人名查 daemon 的 users.json,查不到退回 user id。注意跟轮询有个差别:轮询的人名来自接口
# 响应里的 users[],必然是全的;users.json 是 daemon 异步补的(5 秒 flush 一次),所以
# **第一次见到某个人**时 who 会是裸的 U… id。内容不受影响,只是那一条的人名不好看。
ws_read_items() {
  local cur="$1" dir events names toponly thread
  dir=$(ws_dir); events="$dir/events.jsonl"
  # 文件不存在 = daemon 刚起来还没收到消息,当成空;存在但读不了(权限、挂载点没了)
  # 必须当失败 —— 否则「读不到」会被当成「没有新消息」,游标照推,消息就丢了
  if [ ! -e "$events" ]; then printf '[]'; return 0; fi
  [ -r "$events" ] || { echo "WS 缓冲:$events 存在但读不了" >&2; return 1; }
  names="$dir/users.json"
  [ -r "$names" ] || names=/dev/null

  toponly=false; [ "$MODE" = "top-level" ] && toponly=true
  thread=""; [ "$MODE" = "thread" ] && thread="$THREAD_TS"

  jq -c -n --slurpfile nm "$names" \
     --arg self "$SELF" --argjson prefixes "$PREFIXES" --arg markre "$MARKRE" \
     --argjson max "$BODY_MAX" --arg ch "$CHANNEL" --arg cur "$cur" \
     --arg thread "$thread" --argjson toponly "$toponly" \
     "$AGENT_JQ_DEF"'
     ( ($nm[0] // {}) ) as $names
     | [ inputs
         | select(.ch == $ch)
         | select(.ts > $cur)
         | select(.bot_id == null)
         | select(.user != $self or (.text | is_agent($prefixes; $markre) | not))
         | (.thread_ts // .ts) as $root
         | select($thread == "" or $root == $thread)
         | select(($toponly | not) or $root == .ts)
         | {id: .ts,
            who: ($names[.user // ""] // .user),
            at: .ts,
            kind: (if $root == .ts then "slack-message" else "slack-reply" end),
            thread_ts: (if $root == .ts then null else $root end),
            body: (.text // "")[0:$max]}
       ] | unique_by(.id) | sort_by(.at)' "$events"
}
