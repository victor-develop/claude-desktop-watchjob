#!/bin/bash
# probe-slack-thread.sh 分页回归。
# 覆盖:超过一页(LIMIT+N)取全、从游标起步的跨页增量、翻不完 fail closed(游标不动)、
# 旧版 CLI 取满一页 fail closed。用 PATH 里的假 slackcli 模拟,不打真实 Slack。
#
# 直接跑:bash tests/test-slack-pagination.sh
set -uo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
PROBE="$DIR/../scripts/templates/probe-slack-thread.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

# ---- 假 slackcli(0.9 形状):支持 --oldest / --limit,7 条消息,ts 严格递增 ----
cat > "$TMP/data.json" <<'EOF'
[
  {"ts":"1000000001.000001","user":"U_OTHER","text":"m1"},
  {"ts":"1000000002.000002","user":"U_OTHER","text":"m2"},
  {"ts":"1000000003.000003","user":"U_OTHER","text":"m3"},
  {"ts":"1000000004.000004","user":"U_OTHER","text":"m4"},
  {"ts":"1000000005.000005","user":"U_OTHER","text":"m5"},
  {"ts":"1000000006.000006","user":"U_OTHER","text":"m6"},
  {"ts":"1000000007.000007","user":"U_OTHER","text":"m7"}
]
EOF

mkdir -p "$TMP/new"
cat > "$TMP/new/slackcli" <<EOF
#!/bin/bash
[ "\$1" = "--version" ] && { echo "slackcli 0.9.0"; exit 0; }
[ "\$1" = "conversations" ] || exit 1
oldest=""; limit=100
while [ \$# -gt 0 ]; do
  case "\$1" in
    --oldest) oldest="\$2"; shift 2 ;;
    --limit)  limit="\$2";  shift 2 ;;
    *) shift ;;
  esac
done
jq -c --arg o "\$oldest" --argjson l "\$limit" \
  '{messages: ([ .[] | select((\$o == "") or (.ts > \$o)) ] | sort_by(.ts) | .[0:\$l]), users: []}' \
  "$TMP/data.json"
EOF
chmod +x "$TMP/new/slackcli"

export CHANNEL=C0TEST THREAD_TS=1000000001.000001 SELF=U_ME LIMIT=3 TIMEOUT=10

echo "case 1: 空游标,7 条 > LIMIT=3,应翻页取全"
out=$(PATH="$TMP/new:$PATH" "$PROBE"); rc=$?
n=$(printf '%s' "$out" | jq 'length')
[ $rc -eq 0 ] && [ "$n" = "7" ] && ok "取到 7 条(rc=0)" || bad "rc=$rc n=$n(期望 rc=0 n=7)"

echo "case 2: 游标在 m4,应跨页拿到 m5-m7 共 3 条,无重复"
out=$(PATH="$TMP/new:$PATH" PROBE_CURSOR=1000000004.000004 "$PROBE"); rc=$?
ids=$(printf '%s' "$out" | jq -c '[.[].id]')
[ $rc -eq 0 ] && [ "$ids" = '["1000000005.000005","1000000006.000006","1000000007.000007"]' ] \
  && ok "增量正确 $ids" || bad "rc=$rc ids=$ids"

echo "case 3: MAX_PAGES=1 翻不完,应 exit 3 且不吐结果(游标由调用方保持不动)"
out=$(PATH="$TMP/new:$PATH" MAX_PAGES=1 "$PROBE" 2>"$TMP/err3"); rc=$?
[ $rc -eq 3 ] && [ -z "$out" ] && ok "fail closed(rc=3,无输出)" \
  || { bad "rc=$rc out=$out"; cat "$TMP/err3" >&2; }

echo "case 4: 旧版 CLI(无翻页)取满 LIMIT,应 exit 3"
mkdir -p "$TMP/old"
cat > "$TMP/old/slackcli" <<EOF
#!/bin/bash
[ "\$1" = "--version" ] && { echo "slackcli 0.7.0"; exit 0; }
[ "\$1" = "messages" ] || exit 1
jq -c '{messages: (sort_by(.ts))}' "$TMP/data.json"
EOF
chmod +x "$TMP/old/slackcli"
out=$(PATH="$TMP/old:$PATH" "$PROBE" 2>"$TMP/err4"); rc=$?
[ $rc -eq 3 ] && [ -z "$out" ] && grep -q '无法确认读完' "$TMP/err4" \
  && ok "fail closed(rc=3)" || { bad "rc=$rc out=$out"; cat "$TMP/err4" >&2; }

echo "case 5: 旧版 CLI 不满一页(2 条 < LIMIT),应正常返回"
jq '.[0:2]' "$TMP/data.json" > "$TMP/data2.json"
sed -i '' "s#$TMP/data.json#$TMP/data2.json#" "$TMP/old/slackcli" 2>/dev/null \
  || sed -i "s#$TMP/data.json#$TMP/data2.json#" "$TMP/old/slackcli"
out=$(PATH="$TMP/old:$PATH" "$PROBE"); rc=$?
n=$(printf '%s' "$out" | jq 'length')
[ $rc -eq 0 ] && [ "$n" = "2" ] && ok "取到 2 条(rc=0)" || bad "rc=$rc n=$n"

echo "case 6: 非数字 MAX_PAGES,应 exit 3 且无输出(翻页上限不能静默失效)"
out=$(PATH="$TMP/new:$PATH" MAX_PAGES=abc "$PROBE" 2>"$TMP/err6"); rc=$?
[ $rc -eq 3 ] && [ -z "$out" ] && grep -q 'MAX_PAGES 必须是正整数' "$TMP/err6" \
  && ok "fail closed(rc=3)" || { bad "rc=$rc out=$out"; cat "$TMP/err6" >&2; }

echo "case 7: 非数字 LIMIT,应 exit 3 且无输出"
out=$(PATH="$TMP/new:$PATH" LIMIT=10x "$PROBE" 2>"$TMP/err7"); rc=$?
[ $rc -eq 3 ] && [ -z "$out" ] && ok "fail closed(rc=3)" || { bad "rc=$rc out=$out"; cat "$TMP/err7" >&2; }

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
