#!/bin/bash
# watch-ack.sh 的契约测试,以及它和守护循环并发写 inbox 时不丢项。不碰网络,十几秒跑完。
#
#   ./tests/test-ack.sh

set -uo pipefail
cd "$(dirname "$0")/.."
ACK="$PWD/scripts/watch-ack.sh"; LOOP="$PWD/scripts/watch-loop.sh"
T=$(mktemp -d); trap 'pkill -f "watch-loop.sh --name (race|lockd)" 2>/dev/null; rm -rf "$T"' EXIT
ST="$T/st"; mkdir -p "$ST"; INBOX="$ST/inbox.json"

PASS=0; FAIL=0
expect() {  # $1=描述 $2=实际 $3=期望
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m  %-46s %s\n" "$1" "$2"
  else FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m  %-46s 实际=%s 期望=%s\n" "$1" "$2" "$3"; fi
}
ack() { "$ACK" --name t --state-dir "$ST" "$@" >/dev/null 2>&1; echo $?; }
ids() { jq -c '[.[] | .id // (.who + "|" + .at)]' "$INBOX"; }
three='[{"id":"a1","at":"1"},{"id":"a2","at":"2"},{"who":"bob","at":"3"}]'

echo "watch-ack.sh"
echo "$three" > "$INBOX"
expect "删两项,还剩一项 → 10"            "$(ack --ids a1,bob\|3)" 10
expect "  剩下的是 a2"                    "$(ids)" '["a2"]'
expect "删最后一项 → 0"                    "$(ack --id a2)" 0
expect "  inbox 变成 []"                   "$(ids)" '[]'
echo "$three" > "$INBOX"
expect "id 不存在不算错 → 10(还有项)"    "$(ack --id nope)" 10
expect "  inbox 原样"                      "$(ids)" '["a1","a2","bob|3"]'
expect "不给 id → 1"                       "$(ack)" 1
expect "--ids 空字符串 → 1"                "$(ack --ids '')" 1
expect "--ids 只有逗号 → 1"                "$(ack --ids ',')" 1
echo 'not json' > "$INBOX"
expect "inbox 不是 JSON → 1"               "$(ack --id a1)" 1
expect "  inbox 原样"                      "$(cat "$INBOX")" 'not json'
echo "$three" > "$INBOX"
mkdir "$ST/inbox.lock"
expect "锁被占 → 2"                        "$(WATCH_INBOX_LOCK_TIMEOUT=1 ack --id a1)" 2
expect "  inbox 原样"                      "$(ids)" '["a1","a2","bob|3"]'
touch -t 202001010000 "$ST/inbox.lock"
expect "过期锁被接管 → 10"                "$(ack --id a1)" 10
expect "  锁已释放"                        "$([ -d "$ST/inbox.lock" ] && echo held || echo free)" free
echo '[{"who":7,"at":"9"}]' > "$INBOX"
expect "who 不是字符串也能列出剩余项 → 10"  "$("$ACK" --name t --state-dir "$ST" --id x 2>/dev/null | grep -c '7|9')" 1
mkdir "$ST/inbox.lock"; echo 99999 > "$ST/inbox.lock/pid"
mkdir "$ST/inbox.lock.takeover"; touch -t 202001010000 "$ST/inbox.lock" "$ST/inbox.lock.takeover"
expect "残留的 takeover 也会被清掉 → 0"   "$(ack --id 7\|9)" 0

echo "和守护循环并发"
# 循环每秒 probe 一次:先只吐 r1,之后吐 r1+r2。agent 在 r2 写进来的前后 ack r1,
# 不管谁先拿到锁,最后 inbox 都必须正好是 [r2] —— 不加锁时 ack 整个写回会把 r2 抹掉
cat > "$T/probe.sh" <<'P'
#!/bin/bash
if [ -f "$FLAG" ]; then echo '[{"id":"r1","at":"2026-01-01T10:00:00Z"},{"id":"r2","at":"2026-01-01T10:01:00Z"}]'
else echo '[{"id":"r1","at":"2026-01-01T10:00:00Z"}]'; fi
P
chmod +x "$T/probe.sh"
RS="$T/race"; FLAG="$T/flag"
FLAG="$FLAG" nohup "$LOOP" --name race --probe "$T/probe.sh" --state-dir "$RS" --interval 1 --daemon >/dev/null 2>&1 &
for _ in $(seq 1 40); do [ "$(jq length "$RS/inbox.json" 2>/dev/null)" = "1" ] && break; sleep 0.25; done
expect "循环写进了 r1"                     "$(jq -c 'map(.id)' "$RS/inbox.json" 2>/dev/null)" '["r1"]'
touch "$FLAG"
sleep 0.9   # 让 ack 落在循环下一轮写 r2 的附近
"$ACK" --name race --state-dir "$RS" --id r1 >/dev/null 2>&1
for _ in $(seq 1 40); do [ "$(jq -c 'map(.id)' "$RS/inbox.json")" = '["r2"]' ] && break; sleep 0.25; done
expect "最后 inbox 正好是 [r2]"            "$(jq -c 'map(.id)' "$RS/inbox.json")" '["r2"]'
pkill -f "watch-loop.sh --name race" 2>/dev/null; wait 2>/dev/null

echo "守护循环一直拿不到 inbox 锁"
# 锁被别人一直占着(而且不过期)时,循环要在连续失败到阈值后写 guard-error 叫醒 agent,而不是静默空转
LS="$T/locked"; mkdir -p "$LS/inbox.lock"; echo 99999 > "$LS/inbox.lock/pid"
( while [ -d "$LS/inbox.lock" ]; do touch "$LS/inbox.lock"; sleep 0.5; done ) &
toucher=$!
WATCH_INBOX_LOCK_TIMEOUT=1 WATCH_DAEMON_FAIL_ALERT=2 FLAG="$FLAG" nohup "$LOOP" --name lockd --probe "$T/probe.sh" \
  --state-dir "$LS" --interval 1 --daemon >/dev/null 2>&1 &
for _ in $(seq 1 40); do [ -f "$LS/signal.json" ] && break; sleep 0.25; done
expect "连续拿不到锁 → 写 guard-error"      "$(jq -r .kind "$LS/signal.json" 2>/dev/null)" guard-error
expect "  inbox 没被绕过锁写入"             "$([ -f "$LS/inbox.json" ] && echo written || echo untouched)" untouched
pkill -f "watch-loop.sh --name lockd" 2>/dev/null; rm -rf "$LS/inbox.lock"; wait "$toucher" 2>/dev/null

echo; echo "结果: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
