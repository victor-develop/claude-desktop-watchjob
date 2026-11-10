#!/bin/bash
# WS 事件缓冲模式(SLACK_WS=1)的测试。
#
#   ./tests/test-slack-ws.sh
#
# 不碰网络、不起 daemon:手工摆一个 daemon 的状态目录(status.json / events.jsonl /
# users.json),再用 PATH 前置的假 slackcli 代表「轮询那条路」。断言的核心只有两件事:
#   1. 能用缓冲的时候,一次接口都不打,而且结果跟轮询同形状
#   2. **不敢用缓冲的时候一定退回轮询** —— daemon 没起 / 状态过期 / 游标早于 covered_from /
#      到校验时刻。这条比第 1 条重要:缓冲出问题时静默报「没有新消息」是这套机制最怕的失败

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"; T_DIR="$ROOT/scripts/templates"
PROBE="$T_DIR/probe-slack.sh"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
STUB="$T/stub"; WS="$T/ws"; mkdir -p "$STUB" "$WS"
CALLS="$T/calls"; : > "$CALLS"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m  %s\n" "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"$'\n'"        实际=$2"$'\n'"        期望=$3"; fi; }

# ---------- 假 slackcli:代表轮询那条路,只要被调用到就记一笔 ----------
cat > "$STUB/slackcli" <<STUBEOF
#!/bin/bash
[ "\$1" = "--version" ] && { echo "slackcli 0.9.0"; exit 0; }
echo "\$*" >> "$CALLS"
echo "- Fetching messages..."
echo '{"channel_id":"C_X","messages":[{"ts":"1700000500.000100","user":"U_POLL","text":"轮询才看得到的"}],"has_more":false,"users":[{"id":"U_POLL","name":"poll","real_name":"Poll Path"}]}'
STUBEOF
chmod +x "$STUB/slackcli"
export PATH="$STUB:$PATH"
export RETRY_TIMES=1 RETRY_SLEEP=0

# ---------- 摆一个 daemon 的状态目录 ----------
# 三条消息:顶层、同一 thread 里的回复、另一个频道的(不该被看到)。
# 外加两条「自己」的:带 agent 前缀的要滤掉,本人手打的要留下。
cat > "$WS/events.jsonl" <<'EOF'
{"ch":"C_X","ts":"1700000100.000100","thread_ts":null,"user":"U_ALICE","bot_id":null,"subtype":"","text":"顶层一条","recv":"1700000100.100000"}
{"ch":"C_X","ts":"1700000200.000100","thread_ts":"1700000100.000100","user":"U_ALICE","bot_id":null,"subtype":"","text":"thread 里的回复","recv":"1700000200.100000"}
{"ch":"C_OTHER","ts":"1700000300.000100","thread_ts":null,"user":"U_ALICE","bot_id":null,"subtype":"","text":"别的频道","recv":"1700000300.100000"}
{"ch":"C_X","ts":"1700000400.000100","thread_ts":null,"user":"U_ME","bot_id":null,"subtype":"","text":"[ 🐶 Claude:] agent 用我的号发的","recv":"1700000400.100000"}
{"ch":"C_X","ts":"1700000450.000100","thread_ts":null,"user":"U_ME","bot_id":null,"subtype":"","text":"本人手打:去把它改了","recv":"1700000450.100000"}
EOF
echo '{"U_ALICE":"Alice Example","U_ME":"Me"}' > "$WS/users.json"
echo '{"updated_at":"1700000000.000000","ids":["C_X","C_OTHER"]}' > "$WS/channels.json"
# covered_from 早于下面用的游标;updated_at 用「现在」,这样状态是新鲜的
status() {  # $1=covered_from $2=updated_at 偏移秒(负数 = 多久以前) $3=state
  jq -n --arg cf "$1" --argjson off "$2" --arg st "${3:-READY}" --argjson now "$(date +%s)" \
    '{pid:1, state:$st, epoch:1, covered_from:$cf, connected_from:$cf, retain_floor:null,
      last_frame_at:"1700000450.000100", frames:5, updated_at:(($now + $off)|tostring + ".000000")}' > "$WS/status.json"
}

export CHANNEL=C_X SELF=U_ME SLACK_WS_DIR="$WS" THREAD_CACHE_DIR="$T/cache"
# 快照滞后会把「晚于现在-10s」的项压住;测试数据的 ts 是 2023 年,不受影响
export SNAPSHOT_LAG=10
CUR=1700000000.000000

run() { env "$@" "$PROBE" 2>>"$T/err"; }
polls() { wc -l < "$CALLS" | tr -d ' '; }

echo "== 默认不开 WS:照常轮询,不碰缓冲 =="
: > "$CALLS"; status 1700000000.000000 -1
OUT=$(run PROBE_CURSOR=$CUR SLACK_MODE=top-level)
eq "走了轮询"     "$(echo "$OUT" | jq -r '.[0].who')" "Poll Path"
[ "$(polls)" -gt 0 ] && ok "打了接口" || bad "没打接口"

echo "== 开 WS + 状态新鲜 + 游标够新:一次接口都不打 =="
: > "$CALLS"; status 1700000000.000000 -1
OUT=$(run PROBE_CURSOR=$CUR SLACK_WS=1 SLACK_WS_VERIFY=0 SLACK_MODE=all-threads)
eq "没打接口"       "$(polls)" "0"
eq "3 条(顶层+回复+本人手打,别的频道和 agent 前缀的滤掉)" "$(echo "$OUT" | jq 'length')" "3"
eq "人名从 users.json 来" "$(echo "$OUT" | jq -r '.[0].who')" "Alice Example"
eq "别的频道没进来"  "$(echo "$OUT" | jq '[.[] | select(.body == "别的频道")] | length')" "0"
eq "agent 前缀的滤掉" "$(echo "$OUT" | jq '[.[] | select(.body | test("agent 用我的号"))] | length')" "0"
eq "本人手打的留下"   "$(echo "$OUT" | jq '[.[] | select(.body | test("本人手打"))] | length')" "1"
eq "回复的 kind"     "$(echo "$OUT" | jq -r '[.[] | select(.thread_ts != null) | .kind] | .[0]')" "slack-reply"
eq "回复带 thread_ts" "$(echo "$OUT" | jq -r '[.[] | select(.kind=="slack-reply") | .thread_ts] | .[0]')" "1700000100.000100"
eq "形状跟轮询一致"   "$(echo "$OUT" | jq -c '.[0] | keys')" '["at","body","id","kind","thread_ts","who"]'

echo "== top-level 模式:thread 回复不出现 =="
: > "$CALLS"; status 1700000000.000000 -1
OUT=$(run PROBE_CURSOR=$CUR SLACK_WS=1 SLACK_WS_VERIFY=0 SLACK_MODE=top-level)
eq "没有回复" "$(echo "$OUT" | jq '[.[] | select(.kind=="slack-reply")] | length')" "0"
eq "没打接口" "$(polls)" "0"

echo "== thread 模式:只出这条 thread 的 =="
: > "$CALLS"; status 1700000000.000000 -1
OUT=$(run PROBE_CURSOR=$CUR SLACK_WS=1 SLACK_WS_VERIFY=0 SLACK_MODE=thread THREAD_TS=1700000100.000100)
eq "2 条(父消息 + 回复)" "$(echo "$OUT" | jq 'length')" "2"
eq "没打接口" "$(polls)" "0"

echo "== 游标早于 covered_from:必须退回轮询补齐 =="
: > "$CALLS"; status 1700000300.000000 -1
OUT=$(run PROBE_CURSOR=$CUR SLACK_WS=1 SLACK_MODE=top-level)
eq "走了轮询" "$(echo "$OUT" | jq -r '.[0].who')" "Poll Path"
[ "$(polls)" -gt 0 ] && ok "打了接口" || bad "没打接口"
grep -q "早于 covered_from" "$T/err" && ok "log 里写了原因" || bad "log 里没写原因"

echo "== status.json 过期(daemon 死了):退回轮询 =="
: > "$CALLS"; status 1700000000.000000 -3600
OUT=$(run PROBE_CURSOR=$CUR SLACK_WS=1 SLACK_MODE=top-level)
eq "走了轮询" "$(echo "$OUT" | jq -r '.[0].who')" "Poll Path"

echo "== 会话失效(state 不是 READY):退回轮询 =="
: > "$CALLS"; status 1700000000.000000 -1 AUTH_DEAD
OUT=$(run PROBE_CURSOR=$CUR SLACK_WS=1 SLACK_MODE=top-level)
eq "走了轮询" "$(echo "$OUT" | jq -r '.[0].who')" "Poll Path"

echo "== 根本没有 status.json:退回轮询 =="
: > "$CALLS"; rm -f "$WS/status.json"
OUT=$(run PROBE_CURSOR=$CUR SLACK_WS=1 SLACK_MODE=top-level)
eq "走了轮询" "$(echo "$OUT" | jq -r '.[0].who')" "Poll Path"

echo "== seed(没有游标):退回轮询 =="
: > "$CALLS"; status 1700000000.000000 -1
OUT=$(run SLACK_WS=1 SLACK_MODE=top-level)
eq "走了轮询" "$(echo "$OUT" | jq -r '.[0].who')" "Poll Path"

echo "== 校验周期:第一轮强制轮询对一遍,之后才用缓冲 =="
: > "$CALLS"; status 1700000000.000000 -1; rm -rf "$T/cache"
OUT=$(run PROBE_CURSOR=$CUR SLACK_WS=1 SLACK_MODE=top-level SLACK_WS_VERIFY=1800)
eq "第一轮走轮询" "$(echo "$OUT" | jq -r '.[0].who')" "Poll Path"
: > "$CALLS"
OUT=$(run PROBE_CURSOR=$CUR SLACK_WS=1 SLACK_MODE=top-level SLACK_WS_VERIFY=1800)
eq "第二轮用缓冲" "$(polls)" "0"
: > "$CALLS"
rm -rf "$T/cache"; : > "$CALLS"
OUT=$(run PROBE_CURSOR=$CUR SLACK_WS=1 SLACK_MODE=top-level SLACK_WS_VERIFY=0)
eq "SLACK_WS_VERIFY=0 关掉校验,第一轮就用缓冲" "$(polls)" "0"

echo "== 缓冲文件还不存在:当成空,不报错(daemon 刚起来) =="
: > "$CALLS"; status 1700000000.000000 -1; mv "$WS/events.jsonl" "$T/keep"
OUT=$(run PROBE_CURSOR=$CUR SLACK_WS=1 SLACK_WS_VERIFY=0 SLACK_MODE=top-level); rc=$?
eq "exit 0"   "$rc" "0"
eq "空数组"   "$(echo "$OUT" | jq 'length')" "0"
mv "$T/keep" "$WS/events.jsonl"

echo "== 缓冲文件在但读不了:当失败退回轮询,不能当成「没有新消息」 =="
: > "$CALLS"; status 1700000000.000000 -1; chmod 000 "$WS/events.jsonl"
OUT=$(run PROBE_CURSOR=$CUR SLACK_WS=1 SLACK_WS_VERIFY=0 SLACK_MODE=top-level)
chmod 644 "$WS/events.jsonl"
eq "走了轮询" "$(echo "$OUT" | jq -r '.[0].who')" "Poll Path"

echo "== 频道不在成员名单里:退回轮询(WS 不推没加入的频道) =="
: > "$CALLS"; status 1700000000.000000 -1
echo '{"updated_at":"1700000000.000000","ids":["C_SOMETHING_ELSE"]}' > "$WS/channels.json"
OUT=$(run PROBE_CURSOR=$CUR SLACK_WS=1 SLACK_WS_VERIFY=0 SLACK_MODE=top-level)
eq "走了轮询" "$(echo "$OUT" | jq -r '.[0].who')" "Poll Path"
grep -q "不在 daemon 的成员名单" "$T/err" && ok "log 里写了原因" || bad "log 里没写原因"

echo "== 根本没有成员名单:退回轮询(宁可贵,别静默) =="
: > "$CALLS"; mv "$WS/channels.json" "$T/ch-keep"
OUT=$(run PROBE_CURSOR=$CUR SLACK_WS=1 SLACK_WS_VERIFY=0 SLACK_MODE=top-level)
eq "走了轮询" "$(echo "$OUT" | jq -r '.[0].who')" "Poll Path"
mv "$T/ch-keep" "$WS/channels.json"

echo "== SLACK_WS 给了别的值:直接报错,不要猜 =="
run PROBE_CURSOR=$CUR SLACK_WS=maybe SLACK_MODE=top-level >/dev/null 2>&1
eq "exit 3" "$?" "3"

printf "\n  通过 %d  失败 %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
