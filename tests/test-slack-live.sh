#!/bin/bash
# scripts/slack-live/slack-live.py 的测试。Slack 接口、WebSocket、claude 初判和投递全换成桩,
# 用 --exit-on-eof 回放一段事件流,不碰网络,十几秒跑完。
#
#   ./tests/test-slack-live.sh
#
# 覆盖:本地过滤(私聊 / @我 / @我所在的组 / 投递过的 thread 后续 / 自己 / 自动回复 / 跳过名单 / 改消息)、
#       真人私聊不初判、初判说不用就不投、投递内容不带原文、自动回复说明、search 补拉和实时通道去重、
#       投递失败排队并在下次启动时重投、启动时校验投递配置。

set -uo pipefail
cd "$(dirname "$0")/.."
LIVE="$PWD/scripts/slack-live/slack-live.py"
command -v python3 >/dev/null 2>&1 || { echo "需要 python3"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m  %s\n" "$1"
          else FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m  %s\n" "$1"; fi; }

# Slack 接口桩:按方法名回固定数据;search.messages 读 $T/search.json
cat > "$T/api" <<'EOF'
#!/bin/bash
case "$1" in
  auth.test)          echo '{"ok":true,"user_id":"UME","user":"me"}' ;;
  usergroups.list)    echo '{"ok":true,"usergroups":[{"id":"S1","handle":"team","users":["UME","UBOB"]},{"id":"S2","handle":"other","users":["UBOB"]}]}' ;;
  chat.getPermalink)  echo '{"ok":true,"permalink":"https://example.slack.com/archives/X/p1"}' ;;
  users.info)         echo '{"ok":true,"user":{"name":"bob"}}' ;;
  conversations.replies) echo '{"ok":true,"messages":[{"ts":"9000000001.000100","user":"UBOB","text":"根消息"}]}' ;;
  search.messages)    cat "$SEARCH_FILE" 2>/dev/null || echo '{"ok":true,"messages":{"matches":[]}}' ;;
  *)                  echo '{"ok":true}' ;;
esac
EOF
# WebSocket 桩:把事件文件原样吐出来就结束
cat > "$T/ws" <<'EOF'
#!/bin/bash
cat "$EVENTS_FILE"
EOF
# claude 初判桩:讲 stream-json;正文含 NEED-YES 判需要,/clear 回空;每条 prompt 追加进 $TRIAGE_LOG
cat > "$T/claude" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
for line in sys.stdin:
    content = json.loads(line)["message"]["content"]
    if content == "/clear":
        print(json.dumps({"type": "result", "result": ""}), flush=True)
        continue
    with open(os.environ["TRIAGE_LOG"], "a") as f:
        f.write(content + "\n=====\n")
    need = "NEED-YES" in content.split("<slack-message>", 1)[-1]
    print(json.dumps({"type": "result", "result": json.dumps({"need": need, "reason": "桩判定"})}), flush=True)
EOF
# 投递桩:--check 通过;每次投递把说明全文追加进 $CALLS,FAILS 文件里的数字 > 0 时失败一次
cat > "$T/relay" <<'EOF'
#!/bin/bash
[ "$1" = "--check" ] && exit 0
f=$(cat "$FAILS_FILE" 2>/dev/null || echo 0)
if [ "$f" -gt 0 ]; then echo $((f - 1)) > "$FAILS_FILE"; echo "目标会话不可达" >&2; exit 2; fi
{ cat "$2"; echo; echo "====="; } >> "$CALLS"
echo "已投递到 uds:/tmp/stub.sock"
EOF
chmod +x "$T/api" "$T/ws" "$T/claude" "$T/relay"

export SLACK_LIVE_API_CMD="$T/api" SLACK_LIVE_WS_CMD="$T/ws" SLACK_LIVE_CLAUDE="$T/claude" WATCH_RELAY_CMD="$T/relay"
export SLACK_LIVE_STATE_DIR="$T/st" EVENTS_FILE="$T/events" SEARCH_FILE="$T/search.json"
export TRIAGE_LOG="$T/triage" CALLS="$T/calls" FAILS_FILE="$T/fails"
export SKIP_SENDERS="ci-bot" RELAY_RETRY_SECONDS=0 BACKFILL_SECONDS=3600
export AUTO_REPLY_CHANNELS_FILE="$T/auto-reply" AUTO_REPLY_BYLINE=":robot_face: Auto-reply from agent"
printf 'C1  # 自动回复的频道\n' > "$T/auto-reply"

ev() { local extra="${5:-}"; [ -n "$extra" ] || extra='{}'
  jq -cn --arg ch "$1" --arg ts "$2" --arg user "$3" --arg text "$4" --argjson extra "$extra" \
    '{type:"message", channel:$ch, ts:$ts, user:$user, text:$text} + $extra'; }
run() { python3 "$LIVE" --exit-on-eof >/dev/null 2>&1; echo $?; }
delivered() { grep -c "ts $1" "$CALLS" 2>/dev/null || true; }
triaged() { grep -c "$1" "$TRIAGE_LOG" 2>/dev/null || true; }

echo "== 一段事件流 =="
cat > "$T/search.json" <<'EOF'
{"ok":true,"messages":{"matches":[
  {"ts":"9000000002.000100","user":"UCAT","username":"cat","text":"补拉到的私聊","channel":{"id":"D9","is_im":true},"permalink":"https://example.slack.com/archives/D9/p2"}
]}}
EOF
{
  echo '{"type":"hello"}'
  ev D1 9000000003.000100 UBOB "真人私聊,不用初判"
  ev C1 9000000004.000100 UBOB "<@UME> NEED-YES 帮看下这个问题"
  ev C1 9000000005.000100 UBOB "<@UME> 只是知会一下"
  ev C2 9000000006.000100 UBOB "跟我无关的频道消息"
  ev C3 9000000007.000100 UBOB "<!subteam^S1> NEED-YES 组里谁看下"
  ev C3 9000000007.000200 UBOB "<!subteam^S2> NEED-YES 别的组"
  ev C4 9000000008.000100 UME  "我自己随便说一句"
  ev C4 9000000009.000100 UME  "<@UME> 提醒自己"
  ev C4 9000000010.000100 UME  ":robot_face: Auto-reply from agent
<@UME> 自动回复里提到我"
  ev C1 9000000011.000100 UBOB "NEED-YES 没 @ 但在投递过的 thread 里" '{"thread_ts":"9000000004.000100"}'
  ev C1 9000000011.000200 UBOB "NEED-YES 没 @ 在别的 thread 里" '{"thread_ts":"9000000001.000100"}'
  ev C5 9000000012.000100 UX   "<@UME> CI 通知" '{"username":"ci-bot","bot_id":"B1"}'
  ev C1 9000000013.000100 UBOB "<@UME> NEED-YES 改过的消息" '{"subtype":"message_changed"}'
  ev C1 9000000004.000100 UBOB "<@UME> NEED-YES 帮看下这个问题"
  ev D9 9000000002.000100 UCAT "补拉到的私聊"
} > "$T/events"
rc=$(run)
check "回放结束正常退出" '[ "$rc" = 0 ]'
check "补拉到的私聊投递了" '[ "$(delivered 9000000002.000100)" = 1 ]'
check "实时通道再收到补拉过的那条不重投" '[ "$(delivered 9000000002.000100)" = 1 ]'
check "真人私聊直接投递" '[ "$(delivered 9000000003.000100)" = 1 ]'
check "真人私聊没走初判" '[ "$(triaged "真人私聊,不用初判")" = 0 ]'
check "@我 且初判需要 → 投递" '[ "$(delivered 9000000004.000100)" = 1 ]'
check "同一条重复推送只投一次" '[ "$(delivered 9000000004.000100)" = 1 ]'
check "@我 但初判不需要 → 不投" '[ "$(triaged "只是知会一下")" = 1 ] && [ "$(delivered 9000000005.000100)" = 0 ]'
check "无关频道消息不初判" '[ "$(triaged "跟我无关")" = 0 ]'
check "@我所在的组 → 投递,标出组名" '[ "$(delivered 9000000007.000100)" = 1 ] && grep -q "@用户组 @team" "$CALLS"'
check "@我不在的组 → 不处理" '[ "$(triaged "别的组")" = 0 ] && [ "$(delivered 9000000007.000200)" = 0 ]'
check "我自己的普通消息不处理" '[ "$(delivered 9000000008.000100)" = 0 ]'
check "我 @ 自己 → 不初判直接投" '[ "$(delivered 9000000009.000100)" = 1 ] && [ "$(triaged "提醒自己")" = 0 ]'
check "自动回复(署名开头)不处理" '[ "$(delivered 9000000010.000100)" = 0 ]'
check "投递过的 thread 后续消息 → 初判后投递" '[ "$(delivered 9000000011.000100)" = 1 ] && grep -q "投递过的 thread 里的后续消息" "$CALLS"'
check "没投递过的 thread 里没 @ 的消息不处理" '[ "$(triaged "在别的 thread 里")" = 0 ]'
check "跳过名单里的发送人不处理" '[ "$(triaged "CI 通知")" = 0 ] && [ "$(delivered 9000000012.000100)" = 0 ]'
check "改消息事件不处理" '[ "$(triaged "改过的消息")" = 0 ]'
check "投递说明不带消息原文" '! grep -q "帮看下这个问题" "$CALLS"'
check "初判带上了 thread 前文" 'grep -q "根消息" "$TRIAGE_LOG"'
check "自动回复名单里的频道:说明里有回复命令和署名" 'grep -q "slk-reply.mjs C1 9000000004.000100" "$CALLS" && grep -q "AUTO_REPLY_BYLINE=" "$CALLS"'
check "不在名单里的频道:只起草" 'grep -A3 "ts 9000000007.000100" "$CALLS" | grep -q "不要发 Slack 消息"'
check "seen 记下了处理过的 ts" 'jq -e ".seen | index(\"9000000004.000100\")" "$T/st/state.json" >/dev/null'

echo "== 投递失败:排队,下次启动时重投 =="
: > "$CALLS"; echo 100 > "$FAILS_FILE"
ev D1 9000000020.000100 UBOB "排队的私聊" > "$T/events"; : > "$T/search.json"
run >/dev/null
check "失败的那条进了 pending" '[ "$(jq -r ".pending[0].msg.ts" "$T/st/state.json")" = 9000000020.000100 ]'
check "没投出去" '[ "$(delivered 9000000020.000100)" = 0 ]'
echo 0 > "$FAILS_FILE"; : > "$T/events"
run >/dev/null
check "下次启动时重投成功" '[ "$(delivered 9000000020.000100)" = 1 ]'
check "pending 清空" '[ "$(jq ".pending | length" "$T/st/state.json")" = 0 ]'

echo "== 启动校验 =="
cat > "$T/relay-bad" <<'EOF'
#!/bin/bash
echo "缺少目标会话" >&2; exit 1
EOF
chmod +x "$T/relay-bad"
rc=$(WATCH_RELAY_CMD="$T/relay-bad" python3 "$LIVE" --exit-on-eof >/dev/null 2>&1; echo $?)
check "投递配置不对时直接退出 1" '[ "$rc" = 1 ]'

echo
echo "  通过 $PASS  失败 $FAIL"
[ "$FAIL" -eq 0 ]
