#!/bin/bash
# run_with_timeout 在没有 timeout / gtimeout 时的备用分支。几秒跑完。
#
#   ./tests/test-timeout.sh
#
# 覆盖:正常结束时输出和退出码原样透传 / 超时时命令起的子孙进程一起被杀掉、不留着挂 /
#       看门狗的 sleep 不残留。

set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/templates/_lib.sh

# 让 run_with_timeout 以为机器上没有 timeout 和 gtimeout,走备用分支
command() {
  if [ "${1:-}" = "-v" ] && { [ "${2:-}" = "timeout" ] || [ "${2:-}" = "gtimeout" ]; }; then return 1; fi
  builtin command "$@"
}

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m  %s\n" "$1"
          else FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m  %s\n" "$1"; fi; }

echo "== 正常结束 =="
out=$(run_with_timeout 5 bash -c 'echo hello; exit 3'); rc=$?
check "输出透传" '[ "$out" = "hello" ]'
check "退出码透传" '[ "$rc" = 3 ]'

echo "== 超时:整组杀掉 =="
t0=$(date +%s)
run_with_timeout 2 bash -c 'sleep 300 & echo $! > "$0"; wait' "$T/child" >/dev/null; rc=$?
t1=$(date +%s)
child=$(cat "$T/child")
sleep 0.5
check "超时后返回非 0" '[ "$rc" != 0 ]'
check "按时返回,没等子进程" '[ $((t1 - t0)) -le 4 ]'
check "命令起的子进程也被杀掉" '! kill -0 "$child" 2>/dev/null'

echo "== 看门狗不残留 =="
run_with_timeout 7 true >/dev/null
sleep 0.5
check "没有残留的 sleep 7" '! pgrep -f "^sleep 7$" >/dev/null'

echo
echo "  通过 $PASS  失败 $FAIL"
[ "$FAIL" -eq 0 ]
