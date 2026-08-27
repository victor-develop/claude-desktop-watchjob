#!/bin/bash
# scripts/templates/ 下各模板的测试。
#
#   ./tests/test-templates.sh
#
# 全程不碰网络：gh / slackcli 用 PATH 前置的 stub 顶掉，HTTP 模板用 file:// 读本地文件。
# 验的是模板自己的逻辑：必填校验、自己和 bot 的过滤、排序、terminal 判定、
# 两个源合并时的时间戳归一。

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"; T_DIR="$ROOT/scripts/templates"; LOOP="$ROOT/scripts/watch-loop.sh"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
STUB="$T/stub"; mkdir -p "$STUB"
MODE="$T/mode"; echo open > "$MODE"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m  %s\n" "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"$'\n'"        实际=$2"$'\n'"        期望=$3"; fi; }

# ---------- stub ----------
cat > "$STUB/gh" <<STUBEOF
#!/bin/bash
# 吐真实形状的 GitHub API 载荷，并**真的执行**模板传进来的 --jq 程序。
# 只回预先塑形好的对象是不够的 —— 那样模板 jq 里的引号/语法错误测不出来。
MODE=\$(cat "$MODE")
echo "\$*" >> "$T/gh-args"
if [ "\$MODE" = "reviews-fail" ] && case "\$*" in *reviews*) true ;; *) false ;; esac; then
  echo "HTTP 429: API rate limit exceeded" >&2
  exit 1
fi

JQ_PROG=""; prev=""
for a in "\$@"; do
  [ "\$prev" = "--jq" ] && JQ_PROG="\$a"
  prev="\$a"
done

payload() {
  case "\$*" in
    *issues/*/comments*)
      cat <<'JSON'
[
 {"id":1,"user":{"login":"alice"},"updated_at":"2026-01-01T10:00:00Z","body":"看一下"},
 {"id":9,"user":{"login":"me"},"updated_at":"2026-01-01T09:00:00Z","body":"我自己发的"},
 {"id":8,"user":{"login":"ci-thing[bot]"},"updated_at":"2026-01-01T09:30:00Z","body":"bot 噪音"},
 {"id":7,"user":null,"updated_at":"2026-01-01T09:40:00Z","body":"删号用户留下的"}
]
JSON
      ;;
    *pulls/*/comments*)
      echo '[{"id":1,"user":{"login":"bob"},"updated_at":"2026-01-01T09:50:00Z","path":"a.go","body":"这行"}]' ;;
    *pulls/*/reviews*)
      echo '[{"id":1,"user":{"login":"bob"},"submitted_at":"2026-01-01T11:00:00Z","state":"APPROVED","body":null}]' ;;
    *) echo '[]' ;;
  esac
}

case "\$*" in
  *"pr view"*)   case "\$MODE" in merged) echo MERGED ;; *) echo OPEN ;; esac ;;
  *"pr checks"*)
    case "\$MODE" in
      ci-running) echo '[{"name":"build","state":"IN_PROGRESS","link":"x","bucket":"pending"},{"name":"test","state":"SUCCESS","link":"y","bucket":"pass"}]' ;;
      ci-failed)  echo '[{"name":"build","state":"SUCCESS","link":"x","bucket":"pass"},{"name":"test","state":"FAILURE","link":"y","bucket":"fail"}]' ;;
      ci-cancel)  echo '[{"name":"build","state":"SUCCESS","link":"x","bucket":"pass"},{"name":"test","state":"TIMED_OUT","link":"y","bucket":"cancel"}]' ;;
      ci-green)   echo '[{"name":"build","state":"SUCCESS","link":"x","bucket":"pass"},{"name":"test","state":"SKIPPED","link":"y","bucket":"skipping"}]' ;;
      ci-empty)   exit 1 ;;
      *)          echo '[]' ;;
    esac ;;
  *api*)
    if [ -n "\$JQ_PROG" ]; then payload "\$@" | jq -c "\$JQ_PROG"; else payload "\$@"; fi ;;
esac
exit 0
STUBEOF

cat > "$STUB/slackcli" <<'STUBEOF'
#!/bin/bash
# 两种 slackcli 形态都 stub 出来，模板对两边的兼容都要被测到：
#   conversations read  0.9+：人名在顶层 users[]，消息体里只有 user id；
#                       另外 CLI 会先往 stdout 打一行进度，模板必须掐掉它才是合法 JSON
#   messages            0.7 及更早：消息体自带 user_name，没有 users[]
# STUB_FAIL_FILE 指向一个还不存在的路径时，第一次调用先失败并创建它，之后正常返回。
# 用来测「一次抖动不该打死循环」的重试。
[ -n "${STUB_SLACK_ALWAYS_FAIL:-}" ] && { echo "network unreachable" >&2; exit 1; }
if [ -n "${STUB_FAIL_FILE:-}" ] && [ ! -f "$STUB_FAIL_FILE" ]; then
  : > "$STUB_FAIL_FILE"
  echo "transient network error" >&2
  exit 1
fi
case "$1" in
  conversations)
    # STUB_SLACK_LEGACY=1 模拟只认旧子命令的老 CLI，用来测模板的回退分支
    [ -n "${STUB_SLACK_LEGACY:-}" ] && { echo "unknown command" >&2; exit 1; }
    echo "- Fetching messages..."
    cat <<'JSON'
{"channel_id":"C_X","message_count":4,"messages":[
 {"ts":"1767261600.000100","user":"U_ALICE","text":"thread 里问一句"},
 {"ts":"1767261000.000100","user":"U_ME","text":"我自己发的"},
 {"ts":"1767261300.000100","user":"U_BOT","bot_id":"B1","text":"bot 噪音"},
 {"ts":"1767261400.000100","user":"U_ALICE","subtype":"channel_join","text":"joined"}
],"users":[{"id":"U_ALICE","name":"alice","real_name":"Alice Example"},
           {"id":"U_ME","name":"me","real_name":"Me"}]}
JSON
    ;;
  *)
    cat <<'JSON'
{"messages":[
 {"ts":"1767261600.000100","user":"U_ALICE","user_name":"alice","text":"thread 里问一句"},
 {"ts":"1767261000.000100","user":"U_ME","user_name":"me","text":"我自己发的"},
 {"ts":"1767261300.000100","user":"U_BOT","bot_id":"B1","text":"bot 噪音"},
 {"ts":"1767261400.000100","user":"U_ALICE","subtype":"channel_join","text":"joined"}
]}
JSON
    ;;
esac
STUBEOF
chmod +x "$STUB/gh" "$STUB/slackcli"
export PATH="$STUB:$PATH"
# 失败路径的用例本来就要走完重试才报错。测试里不需要等真实退避，压到 1 次、不睡。
export RETRY_TIMES=1 RETRY_SLEEP=0

# ---------- 1. 语法 ----------
echo "== 语法 =="
n_ok=0; n_all=0
for f in "$T_DIR"/*.sh; do
  n_all=$((n_all+1)); bash -n "$f" 2>/dev/null && n_ok=$((n_ok+1)) || bad "语法错误: $(basename "$f")"
done
eq "$n_all 个模板语法通过" "$n_ok" "$n_all"

# ---------- 2. 必填校验 ----------
echo "== 缺参数要清晰报错（退出 2），而不是吐半个数组 =="
for f in probe-github-pr.sh probe-slack-thread.sh probe-github-checks.sh probe-http-json.sh probe-pr-and-slack.sh; do
  out=$(env -u REPO -u PR -u SELF -u GITHUB_SELF -u CHANNEL -u THREAD_TS -u SLACK_SELF -u URL -u MAP \
        "$T_DIR/$f" 2>&1 >/dev/null); rc=$?
  if [ "$rc" = "2" ] && echo "$out" | grep -q "缺少必需的环境变量"; then ok "$f 缺参数 → exit 2"
  else bad "$f 缺参数 → rc=$rc out=$out"; fi
done

echo "== 缺参数经由循环 → exit 12，且 signal 带 detail =="
rc=$(env -u REPO -u PR -u SELF "$LOOP" --name tpl --probe "$T_DIR/probe-github-pr.sh" \
      --state-dir "$T/st1" --interval 1 --max-runtime 10 >/dev/null 2>&1; echo $?)
eq "exit 12" "$rc" "12"
eq "signal.kind" "$(jq -r '.kind' "$T/st1/signal.json" 2>/dev/null)" "guard-error"
[ -n "$(jq -r '.detail' "$T/st1/signal.json" 2>/dev/null)" ] && ok "signal.detail 非空" || bad "signal.detail 是空的"

# ---------- 3. GitHub PR ----------
echo "== probe-github-pr：过滤自己和 bot、按时间排序 =="
export REPO="owner/repo" PR=123 SELF="me"
OUT=$("$T_DIR/probe-github-pr.sh")
eq "只剩 4 条（自己和 bot 被滤掉，幽灵账号留下）" "$(echo "$OUT" | jq 'length')" "4"
eq "删号用户不崩，记成 ghost" "$(echo "$OUT" | jq -r '[.[] | select(.who=="ghost")] | length')" "1"
eq "按 at 升序"        "$(echo "$OUT" | jq -c '[.[].id]')" '["ic7","rc1","ic1","rv1"]'
eq "没有自己"          "$(echo "$OUT" | jq '[.[] | select(.who == "me")] | length')" "0"
eq "没有 bot"          "$(echo "$OUT" | jq '[.[] | select(.who | test("\\[bot\\]$"))] | length')" "0"
eq "三种 kind 都在"    "$(echo "$OUT" | jq -c '[.[].kind] | sort | unique')" '["pr-comment","pr-inline","pr-review"]'

echo "== probe-github-pr：PR 关掉 → terminal =="
echo merged > "$MODE"
OUT=$("$T_DIR/probe-github-pr.sh")
eq "报 terminal" "$(echo "$OUT" | jq -r '.[0].kind')" "terminal"
eq "带上 state"  "$(echo "$OUT" | jq -r '.[0].state')" "MERGED"
echo "== terminal 经由循环 → exit 11 =="
rc=$("$LOOP" --name tpl2 --probe "$T_DIR/probe-github-pr.sh" --state-dir "$T/st2" \
      --interval 1 --max-runtime 10 >/dev/null 2>&1; echo $?)
eq "exit 11" "$rc" "11"
echo open > "$MODE"

# ---------- 4. CI checks ----------
echo "== probe-github-checks：三种状态 =="
echo ci-running > "$MODE"; eq "还在跑 → 空数组"   "$("$T_DIR/probe-github-checks.sh" | jq 'length')" "0"
echo ci-empty   > "$MODE"; eq "check 还没建 → 空数组" "$("$T_DIR/probe-github-checks.sh" | jq 'length')" "0"
echo ci-failed  > "$MODE"
OUT=$("$T_DIR/probe-github-checks.sh")
eq "红了 → terminal failed" "$(echo "$OUT" | jq -r '.[0].verdict')" "failed"
eq "列出失败的 check"       "$(echo "$OUT" | jq -c '[.[0].failed[].name]')" '["test"]'
echo ci-cancel  > "$MODE"
eq "超时/取消 → 判失败，不是 all-green" "$("$T_DIR/probe-github-checks.sh" | jq -r '.[0].verdict')" "failed"
echo ci-green   > "$MODE"
eq "绿了(含 skipped) → all-green" "$("$T_DIR/probe-github-checks.sh" | jq -r '.[0].verdict')" "all-green"
echo open > "$MODE"

# ---------- 5. Slack ----------
echo "== probe-slack-thread：过滤自己 / bot / 系统消息 =="
export CHANNEL="C0TEST" THREAD_TS="1767260000.000000" SELF="U_ME"
OUT=$("$T_DIR/probe-slack-thread.sh")
eq "只剩 1 条"     "$(echo "$OUT" | jq 'length')" "1"
# 0.9 的输出里消息体只有 user id，人名要从顶层 users[] 关联出来
eq "人名取自 users[]" "$(echo "$OUT" | jq -r '.[0].who')" "Alice Example"
# 老 CLI（只有 messages 子命令）走回退分支，人名退回消息体自带的 user_name
OUT_LEGACY=$(STUB_SLACK_LEGACY=1 "$T_DIR/probe-slack-thread.sh")
eq "老 CLI 回退可用"   "$(echo "$OUT_LEGACY" | jq 'length')" "1"
eq "回退时用 user_name" "$(echo "$OUT_LEGACY" | jq -r '.[0].who')" "alice"

# 取数抖一次就把循环打死的话，每次抖动都要花一次唤醒去重启它 —— 重试掉这一类失败
FAIL_ONCE="$T/slack-failed-once"
OUT_RETRY=$(STUB_FAIL_FILE="$FAIL_ONCE" RETRY_TIMES=2 RETRY_SLEEP=0 "$T_DIR/probe-slack-thread.sh")
eq "抖一次能重试回来" "$(echo "$OUT_RETRY" | jq 'length')" "1"
# 一直失败仍然要失败，不能被重试吞掉
STUB_SLACK_ALWAYS_FAIL=1 RETRY_TIMES=2 RETRY_SLEEP=0 "$T_DIR/probe-slack-thread.sh" >/dev/null 2>&1
eq "一直失败仍 exit 3" "$?" "3"
eq "ts 当游标"     "$(echo "$OUT" | jq -r '.[0].at')" "1767261600.000100"

echo "== TERMINATE_RE 命中 → 标成 terminal =="
eq "命中" "$(TERMINATE_RE='问一句' "$T_DIR/probe-slack-thread.sh" | jq -r '.[0].kind')" "terminal"

# ---------- 6. PR + Slack 合并 ----------
echo "== probe-pr-and-slack：两个源合并，Slack ts 归一成 ISO8601 =="
export GITHUB_SELF="me" SLACK_SELF="U_ME"
OUT=$("$T_DIR/probe-pr-and-slack.sh")
eq "5 条（4 GitHub + 1 Slack）" "$(echo "$OUT" | jq 'length')" "5"
eq "全局按 at 有序"             "$(echo "$OUT" | jq -c '[.[].at] == ([.[].at] | sort)')" "true"
# 亚秒必须保住：todate 截到整秒的话，同一秒内的第二条回复会因为 .at > cursor 不成立而被永久跳过
eq "Slack 归一成 ISO 且保留亚秒" "$(echo "$OUT" | jq -r '.[] | select(.kind=="slack-reply") | .at')" "2026-01-01T10:00:00.000100Z"
eq "raw_at 保留原始 ts"         "$(echo "$OUT" | jq -r '.[] | select(.kind=="slack-reply") | .raw_at')" "1767261600.000100"

# 回归：两个模板单独用时都认 SELF。先测过 Slack 探针的人，环境里会留着 SELF=U_ME，
# 合并版如果把它透传给 GitHub 侧，GitHub 就不再过滤自己 —— 自己的回复把自己叫醒。
echo "== 回归：残留的 SELF 不得污染任一侧 =="
OUT=$(SELF="U_ME" "$T_DIR/probe-pr-and-slack.sh")
eq "仍是 5 条"          "$(echo "$OUT" | jq 'length')" "5"
eq "GitHub 侧仍滤掉自己" "$(echo "$OUT" | jq '[.[] | select(.who == "me")] | length')" "0"
eq "Slack 侧仍滤掉自己"  "$(echo "$OUT" | jq '[.[] | select(.kind=="slack-reply" and .who=="me")] | length')" "0"

# ---------- 6b. 分页 / 失败传播 / 依赖检查 ----------
echo "== 三个 endpoint 都拉，且都带 --paginate =="
rm -f "$T/gh-args"
export REPO="owner/repo" PR=123 GITHUB_SELF="me"
"$T_DIR/probe-github-pr.sh" >/dev/null 2>&1
for ep in "issues/123/comments" "pulls/123/comments" "pulls/123/reviews"; do
  line=$(grep -F "$ep" "$T/gh-args" 2>/dev/null | head -1)
  if [ -z "$line" ]; then bad "没有拉 $ep"
  elif echo "$line" | grep -q -- "--paginate"; then ok "$ep 拉了，且带 --paginate"
  else bad "$ep 拉了，但没带 --paginate（只会拿到第一页）"; fi
done

echo "== 某个 endpoint 失败 → 整个 probe 失败，不得返回半截数据 =="
echo reviews-fail > "$MODE"
OUT=$("$T_DIR/probe-github-pr.sh" 2>/dev/null); rc=$?
eq "probe 退出码" "$rc" "3"
eq "不吐出部分结果（stdout 为空）" "$(printf '%s' "$OUT" | wc -c | tr -d ' ')" "0"
rc=$("$LOOP" --name tpl3 --probe "$T_DIR/probe-github-pr.sh" --state-dir "$T/st3" \
      --interval 1 --max-runtime 10 >/dev/null 2>&1; echo $?)
eq "经由循环 → exit 12（而不是静默推游标）" "$rc" "12"
eq "游标没被推进" "$(cat "$T/st3/cursor" 2>/dev/null || echo '<无>')" "<无>"
echo open > "$MODE"

echo "== 依赖检查 =="
# 注意：_lib.sh 会把 homebrew 追加进 PATH 当兜底，所以剥掉调用方 PATH 也仍然找得到
# 真的 gh/jq。直接测 require_bin 本身，再断言每个模板声明了正确的依赖。
out=$(bash -c '. "$1/_lib.sh"; require_bin definitely-not-a-real-binary-xyz' _ "$T_DIR" 2>&1); rc=$?
if [ "$rc" = "2" ] && echo "$out" | grep -q "缺少必需的命令"; then ok "require_bin 缺命令 → exit 2"
else bad "require_bin → rc=$rc out=$out"; fi

out=$(bash -c '. "$1/_lib.sh"; require_bin gh jq' _ "$T_DIR" 2>&1); rc=$?
eq "require_bin 命令都在 → 通过" "$rc" "0"

for pair in "probe-github-pr.sh:gh jq" "probe-github-checks.sh:gh jq" \
            "probe-slack-thread.sh:slackcli jq" "probe-http-json.sh:curl jq" \
            "probe-pr-and-slack.sh:gh slackcli jq"; do
  f="${pair%%:*}"; want="${pair##*:}"
  got=$(grep -m1 '^require_bin ' "$T_DIR/$f" | sed 's/^require_bin //')
  eq "$f 声明依赖" "$got" "$want"
done
grep -q "^command -v jq" "$LOOP" && ok "watch-loop.sh 自己也检查 jq" || bad "watch-loop.sh 没检查 jq"

# ---------- 7. HTTP JSON ----------
echo "== probe-http-json：MAP 映射 + {{cursor}} 替换 =="
mkdir -p "$T/api"
echo '{"items":[{"id":"t1","updated_at":"2026-01-01T10:00:00Z","title":"aaa","status":"open"}]}' > "$T/api/all.json"
echo '{"items":[{"id":"t2","updated_at":"2026-01-01T12:00:00Z","title":"bbb","status":"done"}]}' > "$T/api/c1.json"
export MAP='[ .items[] | {id:.id, at:.updated_at, kind:"ticket", title:.title, status:.status} ]'

URL="file://$T/api/all.json" OUT=$(URL="file://$T/api/all.json" "$T_DIR/probe-http-json.sh")
eq "MAP 生效" "$(echo "$OUT" | jq -c '[.[].id]')" '["t1"]'

OUT=$(URL="file://$T/api/{{cursor}}.json" PROBE_CURSOR="c1" "$T_DIR/probe-http-json.sh")
eq "{{cursor}} 被替换" "$(echo "$OUT" | jq -r '.[0].id')" "t2"

OUT=$(URL="file://$T/api/nope.json" "$T_DIR/probe-http-json.sh" 2>/dev/null); rc=$?
eq "取不到 → 非 0 退出" "$rc" "3"

echo
echo "  通过 $PASS  失败 $FAIL"
[ "$FAIL" -eq 0 ]
