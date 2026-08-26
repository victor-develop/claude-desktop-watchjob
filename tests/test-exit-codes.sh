#!/bin/bash
# watch-loop.sh 的退出码契约测试。用假 probe，不碰网络，几秒跑完。
#
#   ./tests/test-exit-codes.sh
#
# 覆盖：seed / 10 有新增 / 11 terminal / 12 probe 出错 / 12 probe 输出非法 /
#       13 跑满 max-runtime / 1 同名重复启动被锁挡住 /
#       以及两个数据安全用例：inbox 有未处理项时，控制信号不得覆盖它。

set -uo pipefail
cd "$(dirname "$0")/.."
LOOP="$PWD/scripts/watch-loop.sh"
[ -x "$LOOP" ] || { echo "找不到 $LOOP"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
MODE="$T/mode"

cat > "$T/probe.sh" <<'EOF'
#!/bin/bash
case "$(cat "$MODE_FILE" 2>/dev/null)" in
  empty)    echo '[]' ;;
  one)      echo '[{"id":"a1","who":"alice","at":"2026-01-01T10:00:00Z","kind":"comment","body":"看一下"}]' ;;
  two)      echo '[{"id":"a1","who":"alice","at":"2026-01-01T10:00:00Z","kind":"comment","body":"看一下"},
                   {"id":"a2","who":"bob","at":"2026-01-01T10:05:00Z","kind":"review","body":"approved"}]' ;;
  terminal) echo '[{"kind":"terminal","at":"2026-01-01T11:00:00Z","state":"MERGED"}]' ;;
  fail)     echo "boom" >&2; exit 3 ;;
  garbage)  echo 'not json at all' ;;
esac
EOF
chmod +x "$T/probe.sh"

PASS=0; FAIL=0
mode() { echo "$1" > "$MODE"; }
run()  { MODE_FILE="$MODE" "$LOOP" --name t --probe "$T/probe.sh" --state-dir "$T/st" "$@" >/dev/null 2>&1; echo $?; }

expect() {  # $1=描述 $2=实际 $3=期望
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m  %-42s exit=%s\n" "$1" "$2"
  else FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m  %-42s exit=%s 期望=%s\n" "$1" "$2" "$3"; fi
}
expect_json() {  # $1=描述 $2=jq表达式 $3=文件 $4=期望
  local got; got=$(jq -c "$2" "$3" 2>/dev/null)
  if [ "$got" = "$4" ]; then PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m  %-42s %s\n" "$1" "$got"
  else FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m  %-42s %s 期望=%s\n" "$1" "$got" "$4"; fi
}

echo "== 基本契约 =="
mode one
expect "seed 不唤醒" "$(run --seed)" 0
expect_json "seed 后 inbox 为空" 'length' "$T/st/inbox.json" 0
[ "$(cat "$T/st/cursor")" = "2026-01-01T10:00:00Z" ] \
  && { PASS=$((PASS+1)); echo "  PASS  seed 对齐了游标"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL  seed 没对齐游标"; }

expect "游标生效后不再唤醒（跑满）" "$(run --interval 1 --max-runtime 3)" 13

printf '' > "$T/st/cursor"
expect "有新增" "$(run --interval 1 --max-runtime 20)" 10
expect_json "inbox 只含数据项" '[.[].id]' "$T/st/inbox.json" '["a1"]'
expect_json "signal 报 new-items" '.kind' "$T/st/signal.json" '"new-items"'

mode two
expect "增量合并" "$(run --interval 1 --max-runtime 20)" 10
expect_json "合并后去重且有序" '[.[].id]' "$T/st/inbox.json" '["a1","a2"]'

echo "== 数据安全：控制信号不得覆盖 inbox =="
mode empty
expect "max-runtime" "$(run --interval 1 --max-runtime 3)" 13
expect_json "inbox 未被 max-runtime 覆盖" '[.[].id]' "$T/st/inbox.json" '["a1","a2"]'

mode fail
expect "probe 出错" "$(run --interval 1 --max-runtime 20)" 12
expect_json "inbox 未被 guard-error 覆盖" '[.[].id]' "$T/st/inbox.json" '["a1","a2"]'
expect_json "signal 带 detail" '.kind' "$T/st/signal.json" '"guard-error"'

mode garbage
expect "probe 输出非 JSON 数组" "$(run --interval 1 --max-runtime 20)" 12

echo "== terminal =="
mode terminal
expect "terminal" "$(run --interval 1 --max-runtime 20)" 11
expect_json "terminal 项进了 inbox" '.[-1].kind' "$T/st/inbox.json" '"terminal"'

echo "== 参数校验：非数字不得导致满速空转 =="
# --interval 非数字时，sleep 每轮立刻失败，循环满速刷 probe、永不退出、也永不唤醒 agent。
# 这正好是本项目宣称的「唯一不告警的失效方式」，必须在启动前挡住。
mode empty
expect "--interval 非数字被拒" "$(run --interval abc --max-runtime 3)" 1
expect "--interval 为 0 被拒"  "$(run --interval 0 --max-runtime 3)" 1
expect "--max-runtime 非数字被拒" "$(run --interval 1 --max-runtime xyz)" 1
t0=$(date +%s); run --interval abc --max-runtime 3 >/dev/null 2>&1; t1=$(date +%s)
if [ $((t1 - t0)) -le 2 ]; then PASS=$((PASS+1)); echo "  PASS  被拒后立刻退出，没有空转"
else FAIL=$((FAIL+1)); echo "  FAIL  被拒后还跑了 $((t1-t0))s"; fi

echo "== 数据安全：inbox 损坏时不得覆盖它 =="
# 合并用 jq --argjson 读 inbox。inbox 若被截断/写坏，jq 失败；早先的版本不检查退出码，
# 会把 inbox 覆盖成空、游标照推、还通知 agent「有新增」—— 未处理的项永久消失。
printf '[{"id":"a1","who":"alice",' > "$T/st/inbox.json"     # 半个 JSON
printf '' > "$T/st/cursor"
mode one
expect "inbox 损坏 → exit 12" "$(run --interval 1 --max-runtime 10)" 12
expect_json "signal 说明原因" '.kind' "$T/st/signal.json" '"guard-error"'
if grep -q '{"id":"a1","who":"alice",$' "$T/st/inbox.json"; then
  PASS=$((PASS+1)); echo "  PASS  损坏的 inbox 原样保留，没被覆盖"
else FAIL=$((FAIL+1)); echo "  FAIL  inbox 被动过了：$(cat "$T/st/inbox.json")"; fi
expect "游标没被推进" "$(cat "$T/st/cursor")" ""

echo "== probe 吐非字符串 kind 不得触发同一条丢失路径 =="
printf '[]' > "$T/st/inbox.json"; printf '' > "$T/st/cursor"
cat > "$T/probe-oddkind.sh" <<'ODD'
#!/bin/bash
echo '[{"id":"k1","who":"alice","at":"2026-01-01T10:00:00Z","kind":42,"body":"kind 是数字"}]'
ODD
chmod +x "$T/probe-oddkind.sh"
rc=$("$LOOP" --name t --probe "$T/probe-oddkind.sh" --state-dir "$T/st" --interval 1 --max-runtime 10 >/dev/null 2>&1; echo $?)
expect "非字符串 kind → 正常 exit 10" "$rc" 10
expect_json "该项进了 inbox，没被吃掉" '[.[].id]' "$T/st/inbox.json" '["k1"]'

echo "== 同名互斥 =="
mode empty
MODE_FILE="$MODE" "$LOOP" --name t --probe "$T/probe.sh" --state-dir "$T/st" \
  --interval 1 --max-runtime 6 >/dev/null 2>&1 &
BG=$!
sleep 1
expect "同名重复启动被挡" "$(run --interval 1 --max-runtime 6)" 1
wait $BG 2>/dev/null

echo
echo "  通过 $PASS  失败 $FAIL"
[ "$FAIL" -eq 0 ]
