#!/bin/bash
# probe-slack.sh 三种模式(thread / top-level / all-threads)的测试。
#
#   ./tests/test-slack-modes.sh
#
# 不碰网络:PATH 前置一个假 slackcli,按 0.9 的输出形状、Slack 的分页语义回数据
# (会话历史 = 只有顶层消息,reply_count 按 thread 文件现算;--oldest 严格大于;has_more)。
# 每次调用记进 calls,用来断言「没有新回复的 thread 不会被拉」。
#
# 覆盖:thread 回复能抓到、自己带前缀的被滤掉而本人手打的保留、bot 被滤掉、
# 三种模式输出形状一致、游标经 watch-loop 正确推进、没变化的 thread 不重拉、
# 循环没推进游标时缓存不会吞掉回复、换模式不用重新 seed、旧入口兼容、出错 fail closed。

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"; T_DIR="$ROOT/scripts/templates"; LOOP="$ROOT/scripts/watch-loop.sh"
PROBE="$T_DIR/probe-slack.sh"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
D="$T/data"; STUB="$T/stub"; mkdir -p "$D" "$STUB"
CALLS="$T/calls"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m  %s\n" "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"$'\n'"        实际=$2"$'\n'"        期望=$3"; fi; }

# ---------- 假 slackcli ----------
cat > "$STUB/slackcli" <<STUBEOF
#!/bin/bash
[ "\$1" = "--version" ] && { echo "slackcli 0.9.0"; exit 0; }
echo "\$*" >> "$CALLS"
[ "\$1" = "conversations" ] && [ "\$2" = "read" ] || exit 1
shift 2; ch="\$1"; shift
thr=""; oldest=""; limit=100
while [ \$# -gt 0 ]; do
  case "\$1" in
    --thread-ts) thr="\$2"; shift 2 ;;
    --oldest)    oldest="\$2"; shift 2 ;;
    --limit)     limit="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "\$thr" ] && [ "\$thr" = "\${STUB_FAIL_THREAD:-}" ] && { echo "thread fetch boom" >&2; exit 1; }
# STUB_RACE_FLAG 指向不存在的文件时:第一次拉 thread 之前,模拟「顶层读完之后」有人先发了一条
# 顶层消息、紧接着在 thread 里回了一条(两条 ts 都是现在)
if [ -n "\$thr" ] && [ -n "\${STUB_RACE_FLAG:-}" ] && [ ! -f "\$STUB_RACE_FLAG" ]; then
  : > "\$STUB_RACE_FLAG"; now=\$(date +%s)
  jq --arg ts "\$((now - 1)).000100" '. + [{ts:\$ts, user:"U_ALICE", text:"读完顶层之后才发的顶层"}]' "$D/history.json" > "$D/h.tmp" && mv "$D/h.tmp" "$D/history.json"
  jq --arg ts "\$now.000200" --arg p "\$thr" '. + [{ts:\$ts, thread_ts:\$p, user:"U_ALICE", text:"紧接着回在 thread 里"}]' "$D/thread-\$thr.json" > "$D/t.tmp" && mv "$D/t.tmp" "$D/thread-\$thr.json"
fi
echo "- Fetching messages..."
if [ -n "\$thr" ]; then
  jq -c --arg o "\$oldest" --argjson l "\$limit" '
    (sort_by(.ts) | map(select((\$o == "") or (.ts > \$o)))) as \$all
    | {channel_id: "C", messages: \$all[0:\$l], has_more: ((\$all | length) > \$l),
       users: [{id:"U_ALICE", name:"alice", real_name:"Alice Example"}]}' "$D/thread-\$thr.json"
else
  # 会话历史:只有顶层;reply_count 按 thread 文件现算;STUB_LATEST=1 时带 latest_reply
  jq -c --arg o "\$oldest" --argjson l "\$limit" '
    (sort_by(.ts) | map(select((\$o == "") or (.ts > \$o)))) as \$all
    | (if \$o == "" then \$all[-\$l:] else \$all[0:\$l] end) as \$page
    | {channel_id: "C", messages: \$page, has_more: ((\$all | length) > \$l),
       users: [{id:"U_ALICE", name:"alice", real_name:"Alice Example"}]}' "$D/history.json" \
  | while IFS= read -r line; do
      # 给有 thread 文件的父消息补 reply_count(/latest_reply)
      out="\$line"
      for f in "$D"/thread-*.json; do
        [ -f "\$f" ] || continue
        ts=\$(basename "\$f" .json); ts=\${ts#thread-}
        n=\$(jq 'length - 1' "\$f"); lr=\$(jq -r 'map(.ts) | max' "\$f")
        out=\$(printf '%s' "\$out" | jq -c --arg ts "\$ts" --argjson n "\$n" --arg lr "\$lr" --arg latest "\${STUB_LATEST:-}" '
          .messages |= map(if .ts == \$ts then . + {reply_count: \$n}
                                   + (if \$latest == "1" then {latest_reply: \$lr} else {} end) else . end)')
      done
      printf '%s\n' "\$out"
    done
fi
STUBEOF
chmod +x "$STUB/slackcli"
export PATH="$STUB:$PATH"

# ---------- 数据 ----------
P1=1000000100.000100; P3=1000000300.000100
cat > "$D/history.json" <<EOF
[
 {"ts":"$P1","thread_ts":"$P1","user":"U_ALICE","text":"顶层 P1,底下有 thread"},
 {"ts":"1000000200.000100","user":"U_ALICE","text":"顶层 M2,没有 thread"},
 {"ts":"$P3","thread_ts":"$P3","user":"U_ME","text":"本人手打的顶层 P3"}
]
EOF
cat > "$D/thread-$P1.json" <<EOF
[
 {"ts":"$P1","thread_ts":"$P1","user":"U_ALICE","text":"顶层 P1,底下有 thread"},
 {"ts":"1000000150.000100","thread_ts":"$P1","user":"U_ALICE","text":"R1 alice 回在 thread 里"},
 {"ts":"1000000250.000100","thread_ts":"$P1","user":"U_ME","text":"[ :dog: Claude:] R2 agent 代发的"},
 {"ts":"1000000260.000100","thread_ts":"$P1","user":"U_ME","text":"R3 本人手打"},
 {"ts":"1000000270.000100","thread_ts":"$P1","user":"U_BOT","bot_id":"B1","text":"R4 bot"}
]
EOF
cat > "$D/thread-$P3.json" <<EOF
[
 {"ts":"$P3","thread_ts":"$P3","user":"U_ME","text":"本人手打的顶层 P3"},
 {"ts":"1000000350.000100","thread_ts":"$P3","user":"U_ALICE","text":"R5 alice"}
]
EOF
add_reply() {  # $1=父 ts $2=ts $3=user $4=text
  jq --arg ts "$2" --arg p "$1" --arg u "$3" --arg t "$4" '. + [{ts:$ts, thread_ts:$p, user:$u, text:$t}]' \
    "$D/thread-$1.json" > "$D/tmp" && mv "$D/tmp" "$D/thread-$1.json"
}
thread_calls() { grep -c -- '--thread-ts' "$CALLS" 2>/dev/null || true; }
ids() { jq -c '[.[].id | split(".")[0] | .[7:10]]'; }   # 1000000150.000100 → "150",好读

export CHANNEL=D0TEST SELF=U_ME SLACKCLI_ALLOW_UNTESTED=0 RETRY_TIMES=1 RETRY_SLEEP=0 TIMEOUT=10
export THREAD_CACHE_DIR="$T/cache"
unset SLACK_MODE THREAD_TS EXCLUDE_REPLIES SELF_KEEP_HUMAN AGENT_MARK AGENT_MARK_RE SLACK_SELF

echo "== 参数校验 =="
SLACK_MODE=bogus "$PROBE" >/dev/null 2>&1; eq "SLACK_MODE 非法 → exit 3" "$?" "3"
SLACK_MODE=all-threads EXCLUDE_REPLIES=1 "$PROBE" >/dev/null 2>&1; eq "EXCLUDE_REPLIES=1 + all-threads 矛盾 → exit 3" "$?" "3"
THREAD_SCAN=abc "$PROBE" >/dev/null 2>&1; eq "THREAD_SCAN 非数字 → exit 3" "$?" "3"
SLACK_MODE=thread "$PROBE" >/dev/null 2>&1; eq "thread 模式缺 THREAD_TS → exit 2" "$?" "2"

echo "== all-threads:thread 回复能抓到,过滤规则对 =="
OUT=$(PROBE_CURSOR=1000000140.000000 SELF_KEEP_HUMAN=1 SLACK_MODE=all-threads "$PROBE"); rc=$?
eq "exit 0" "$rc" "0"
eq "顶层 + 两个 thread 的回复,自己带前缀的 / bot 被滤" "$(echo "$OUT" | ids)" '["150","200","260","300","350"]'
eq "回复:kind=slack-reply,thread_ts=父消息" \
   "$(echo "$OUT" | jq -c '.[] | select(.id=="1000000150.000100") | [.kind, .thread_ts, .who]')" \
   "[\"slack-reply\",\"$P1\",\"Alice Example\"]"
eq "顶层:kind=slack-message,thread_ts=null" \
   "$(echo "$OUT" | jq -c '.[] | select(.id=="1000000200.000100") | [.kind, .thread_ts]')" '["slack-message",null]'
eq "每项字段一致" "$(echo "$OUT" | jq -c '[.[] | keys] | unique')" '[["at","body","id","kind","thread_ts","who"]]'

OUT=$(PROBE_CURSOR=1000000140.000000 SLACK_MODE=all-threads THREAD_CACHE_DIR="$T/c-nokeep" "$PROBE")
eq "不开 SELF_KEEP_HUMAN:本人的消息全滤" "$(echo "$OUT" | ids)" '["150","200","350"]'
OUT=$(PROBE_CURSOR=1000000140.000000 SLACK_MODE=all-threads THREAD_CACHE_DIR="$T/c-mark" AGENT_MARK_RE='^\[ (:dog:|🐶) Claude:\]' "$PROBE")
eq "AGENT_MARK_RE 在 all-threads 下也生效" "$(echo "$OUT" | ids)" '["150","200","260","300","350"]'

echo "== top-level:不碰 thread =="
: > "$CALLS"
OUT=$(PROBE_CURSOR=1000000140.000000 SLACK_MODE=top-level "$PROBE")
eq "只有顶层" "$(echo "$OUT" | ids)" '["200"]'
eq "没有任何 --thread-ts 调用" "$(thread_calls)" "0"
eq "每轮只打 1 次接口" "$(wc -l < "$CALLS" | tr -d ' ')" "1"
OUT=$(PROBE_CURSOR=1000000140.000000 EXCLUDE_REPLIES=1 "$PROBE")
eq "EXCLUDE_REPLIES=1 等于 top-level" "$(echo "$OUT" | ids)" '["200"]'

echo "== thread:只看指定那条 =="
OUT=$(PROBE_CURSOR=1000000140.000000 THREAD_TS=$P1 SELF_KEEP_HUMAN=1 "$PROBE")
eq "给了 THREAD_TS 默认就是 thread 模式" "$(echo "$OUT" | ids)" '["150","260"]'
eq "thread 模式形状一致" "$(echo "$OUT" | jq -c '[.[] | [.kind, .thread_ts]] | unique')" "[[\"slack-reply\",\"$P1\"]]"
OUT2=$(PROBE_CURSOR=1000000140.000000 THREAD_TS=$P1 SELF_KEEP_HUMAN=1 SLACK_MODE=all-threads "$T_DIR/probe-slack-thread.sh")
eq "旧入口 probe-slack-thread.sh 输出相同(且无视外面的 SLACK_MODE)" "$OUT2" "$OUT"
OUT=$(THREAD_TS=$P1 LIMIT=2 SELF_KEEP_HUMAN=1 "$PROBE")
eq "没游标 + LIMIT=2:翻页取全(父消息 kind=slack-message)" \
   "$(echo "$OUT" | jq -c '[.[] | [(.id|.[7:10]), .kind]]')" \
   '[["100","slack-message"],["150","slack-reply"],["260","slack-reply"]]'

echo "== 旧入口 probe-slack-channel.sh:默认 all-threads,THREAD_TS 不会把它变成 thread 模式 =="
OUT=$(PROBE_CURSOR=1000000140.000000 THREAD_TS=$P3 SELF_KEEP_HUMAN=1 THREAD_CACHE_DIR="$T/c-wrap" "$T_DIR/probe-slack-channel.sh")
eq "能看到 thread 回复" "$(echo "$OUT" | ids)" '["150","200","260","300","350"]'
OUT=$(PROBE_CURSOR=1000000140.000000 EXCLUDE_REPLIES=1 "$T_DIR/probe-slack-channel.sh")
eq "EXCLUDE_REPLIES=1 仍是只看顶层" "$(echo "$OUT" | ids)" '["200"]'

echo "== 经 watch-loop:游标推进 + 没变化的 thread 不重拉 =="
rm -rf "$T/cache"; ST="$T/st"
run() { SELF_KEEP_HUMAN=1 "$LOOP" --name m --probe "$T_DIR/probe-slack-channel.sh" --state-dir "$ST" "$@" >/dev/null 2>&1; echo $?; }
eq "seed" "$(run --seed)" "0"
eq "seed 后游标 = 所有可见消息里最新的(含 thread 回复)" "$(cat "$ST/cursor")" "1000000350.000100"
: > "$CALLS"
eq "没新消息 → 跑满 13" "$(run --interval 1 --max-runtime 3)" "13"
: > "$CALLS"
OUT=$(SELF_KEEP_HUMAN=1 PROBE_CURSOR=$(cat "$ST/cursor") "$T_DIR/probe-slack-channel.sh")
eq "缓存热了之后:没有新东西" "$OUT" "[]"
eq "稳态没有 thread 被重拉,每轮只有 2 次请求" "$(thread_calls) $(wc -l < "$CALLS" | tr -d ' ')" "0 2"

add_reply $P1 1000000400.000100 U_ALICE "R6 新回复,回在旧 thread 里"
: > "$CALLS"
eq "thread 里有新回复 → 叫醒 10" "$(run --interval 1 --max-runtime 20)" "10"
eq "inbox 拿到这条回复" "$(jq -c '[.[] | [(.id|.[7:10]), .kind, .thread_ts]]' "$ST/inbox.json")" "[[\"400\",\"slack-reply\",\"$P1\"]]"
eq "游标推进到这条回复" "$(cat "$ST/cursor")" "1000000400.000100"
eq "只拉了有变化的那条 thread" "$(grep -- '--thread-ts' "$CALLS" | grep -c -- "$P3")" "0"
: > "$CALLS"
: > "$CALLS"; SELF_KEEP_HUMAN=1 PROBE_CURSOR=$(cat "$ST/cursor") "$T_DIR/probe-slack-channel.sh" >/dev/null
eq "回复数刚变的 thread 下一轮再确认一次" "$(grep -- '--thread-ts' "$CALLS" | grep -c -- "$P1")" "1"
: > "$CALLS"; SELF_KEEP_HUMAN=1 PROBE_CURSOR=$(cat "$ST/cursor") "$T_DIR/probe-slack-channel.sh" >/dev/null
eq "确认过之后不再重拉" "$(thread_calls)" "0"

echo "== 最后一条回复是自己发的:照样能跳过,不会每轮重拉 =="
add_reply $P1 1000000410.000100 U_ME "[ 🐶 Claude:] agent 回了一句"
for i in 1 2; do SELF_KEEP_HUMAN=1 PROBE_CURSOR=$(cat "$ST/cursor") "$T_DIR/probe-slack-channel.sh" >/dev/null; done
: > "$CALLS"
OUT=$(SELF_KEEP_HUMAN=1 PROBE_CURSOR=$(cat "$ST/cursor") "$T_DIR/probe-slack-channel.sh")
eq "自己的回复不叫醒" "$OUT" "[]"
eq "第三轮起不再拉这个 thread" "$(thread_calls)" "0"

echo "== 循环没推进游标时,缓存不会吞掉回复 =="
add_reply $P3 1000000450.000100 U_ALICE "R7"
OUT=$(PROBE_CURSOR=1000000400.000100 SLACK_MODE=all-threads "$PROBE")
eq "第一次拿到 R7" "$(echo "$OUT" | ids)" '["450"]'
OUT=$(PROBE_CURSOR=1000000400.000100 SLACK_MODE=all-threads "$PROBE")
eq "游标没动,再跑一次还拿得到 R7" "$(echo "$OUT" | ids)" '["450"]'

echo "== 换模式不用重新 seed:top-level → all-threads =="
ST2="$T/st2"; rm -rf "$T/cache"
eq "top-level seed" "$(SLACK_MODE=top-level SELF_KEEP_HUMAN=1 "$LOOP" --name m2 --probe "$PROBE" --state-dir "$ST2" --seed >/dev/null 2>&1; echo $?)" "0"
eq "游标 = 最新顶层" "$(cat "$ST2/cursor")" "$P3"
rc=$(SLACK_MODE=all-threads SELF_KEEP_HUMAN=1 "$LOOP" --name m2 --probe "$PROBE" --state-dir "$ST2" --interval 1 --max-runtime 20 >/dev/null 2>&1; echo $?)
eq "切到 all-threads → 10" "$rc" "10"
eq "补上游标之后发在 thread 里的回复,顶层不重复" "$(jq -c '[.[].id | .[7:10]]' "$ST2/inbox.json")" '["350","400","450"]'

echo "== latest_reply 可用时,没缓存也能跳过 thread =="
rm -rf "$T/cache"; : > "$CALLS"
OUT=$(STUB_LATEST=1 PROBE_CURSOR=1000000450.000100 SLACK_MODE=all-threads "$PROBE")
eq "没有新东西" "$OUT" "[]"
eq "一个 thread 都没拉" "$(thread_calls)" "0"
rm -rf "$T/cache"; : > "$CALLS"
OUT=$(STUB_LATEST=1 PROBE_CURSOR=1000000420.000100 SLACK_MODE=all-threads "$PROBE")
eq "只有 P3 的 latest_reply 晚于游标" "$(echo "$OUT" | ids)" '["450"]'
eq "只拉了 P3" "$(grep -- '--thread-ts' "$CALLS" | sed 's/.*--thread-ts \([^ ]*\).*/\1/' | sort -u | tr '\n' ' ')" "$P3 "

echo "== 一轮里先后读多个源:后读到的新回复不会把先读时还没出现的顶层消息越过去 =="
rm -rf "$T/cache"; ST3="$T/st3"
run3() { SLACK_MODE=all-threads SELF_KEEP_HUMAN=1 "$LOOP" --name m3 --probe "$PROBE" --state-dir "$ST3" "$@" >/dev/null 2>&1; echo $?; }
eq "seed" "$(run3 --seed)" "0"
rm -rf "$T/cache"   # 让下一轮一定去拉 thread,竞态才会出现
OUT=$(STUB_RACE_FLAG="$T/race" SLACK_MODE=all-threads SELF_KEEP_HUMAN=1 PROBE_CURSOR=$(cat "$ST3/cursor") "$PROBE")
eq "竞态这一轮:晚于快照的都先不交" "$OUT" "[]"
OUT=$(SLACK_MODE=all-threads SELF_KEEP_HUMAN=1 SNAPSHOT_LAG=0 PROBE_CURSOR=$(cat "$ST3/cursor") "$PROBE")
eq "过了快照之后:顶层和 thread 回复都拿到" "$(echo "$OUT" | jq -c '[.[].body]')" '["读完顶层之后才发的顶层","紧接着回在 thread 里"]'
SNAPSHOT_LAG=x "$PROBE" >/dev/null 2>&1; eq "SNAPSHOT_LAG 非数字 → exit 3" "$?" "3"

echo "== 缓存文件坏了不会把 thread 全跳过 =="
for f in "$T/cache"/*.json; do printf '{"%s":"x","%s":{"n":"bad"}}' "$P1" "$P3" > "$f"; done
OUT=$(SLACK_MODE=all-threads SELF_KEEP_HUMAN=1 PROBE_CURSOR=1000000440.000100 "$PROBE"); rc=$?
eq "照样拉 thread,拿到 R7" "$rc $(echo "$OUT" | jq -c '[.[].id | .[7:10]] | map(select(. == "450"))')" '0 ["450"]'

echo "== 出错 fail closed =="
rm -rf "$T/cache"
OUT=$(STUB_FAIL_THREAD=$P3 PROBE_CURSOR=1000000140.000000 SLACK_MODE=all-threads "$PROBE" 2>/dev/null); rc=$?
eq "某个 thread 拉不到 → exit 3" "$rc" "3"
eq "且不吐半个数组" "$OUT" ""

echo
echo "  通过 $PASS  失败 $FAIL"
[ "$FAIL" -eq 0 ]
