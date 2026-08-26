#!/bin/bash
# 并行隔离测试：同时跑 N 个 watch，验证各自独立。
#
#   ./tests/test-parallel.sh [N]      # 默认 5
#
# 验的是：独立 pid / 独立锁 / 独立 signal（名字和运行时长各自正确）/ 不串状态。
#
# 测不到的部分：harness 层面「每个循环退出各自发一条通知给 agent」。那个要在 Claude
# Desktop 里用 Bash 工具的 run_in_background 启动才能观察 —— 实测 5 个并行 5 条通知
# 一条不丢，记在 references/mechanics.md。本脚本只验进程和状态的隔离。

set -uo pipefail
cd "$(dirname "$0")/.."
LOOP="$PWD/scripts/watch-loop.sh"
N="${1:-5}"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf '#!/bin/bash\necho "[]"\n' > "$T/probe.sh"; chmod +x "$T/probe.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m  %s\n" "$1"; }

echo "== 启动 $N 个循环，错开退出 =="
for i in $(seq 1 "$N"); do
  rt=$((i * 4 + 4))          # 8s, 12s, 16s, ...
  "$LOOP" --name "p$i" --probe "$T/probe.sh" --state-dir "$T/p$i" \
    --interval 2 --max-runtime "$rt" >/dev/null 2>&1 &
  echo "  p$i max-runtime=${rt}s pid=$!"
done

sleep 3
echo "== 运行中：pid 和锁应各自独立 =="
pids=""
for i in $(seq 1 "$N"); do
  p=$(cat "$T/p$i/lock/pid" 2>/dev/null || echo "")
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && pids="$pids $p" \
    || bad "p$i 没在跑"
done
uniq_n=$(echo $pids | tr ' ' '\n' | sort -u | grep -c . || true)
[ "$uniq_n" -eq "$N" ] && ok "$N 个独立 pid（无复用）" || bad "pid 不独立：$uniq_n/$N"

lock_n=$(ls -d "$T"/p*/lock 2>/dev/null | wc -l | tr -d ' ')
[ "$lock_n" -eq "$N" ] && ok "$N 个独立锁目录" || bad "锁目录 $lock_n/$N"

echo "== 等全部退出 =="
wait

for i in $(seq 1 "$N"); do
  rt=$((i * 4 + 4))
  got_name=$(jq -r '.watch' "$T/p$i/signal.json" 2>/dev/null)
  got_rt=$(jq -r '.ran_seconds' "$T/p$i/signal.json" 2>/dev/null)
  got_kind=$(jq -r '.kind' "$T/p$i/signal.json" 2>/dev/null)
  if [ "$got_name" = "p$i" ] && [ "$got_rt" = "$rt" ] && [ "$got_kind" = "max-runtime" ]; then
    ok "p$i signal 正确（watch=$got_name ran=${got_rt}s）"
  else
    bad "p$i signal 串了：kind=$got_kind watch=$got_name ran=$got_rt（期望 p$i / $rt）"
  fi
done

echo "== 锁已释放 =="
left=$(ls -d "$T"/p*/lock 2>/dev/null | wc -l | tr -d ' ')
[ "$left" -eq 0 ] && ok "全部锁已清理" || bad "还剩 $left 个锁目录没清"

echo
echo "  通过 $PASS  失败 $FAIL"
[ "$FAIL" -eq 0 ]
