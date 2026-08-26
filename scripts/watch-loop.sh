#!/bin/bash
# 通用增量 watch 循环。睡在后台,只在「有值得叫醒 agent 的事」时退出。
#
# 用 Bash 工具的 run_in_background 启动 —— 脚本跨轮次存活,退出时 harness 自动唤醒 agent。
# 睡着的时候 0 token。
#
# 用法:
#   watch-loop.sh --name <名字> --probe <probe脚本> [选项]
#
# 选项:
#   --interval N        轮询间隔秒,默认 120
#   --max-runtime N     最长跑多久(秒),到点退出 13 让 agent 重新拉起,默认 5400(90min)
#   --backoff           连续无事时间隔翻倍,上限 interval*8。适合低频源
#   --active HH-HH      只在这个小时区间内轮询,窗口外空转(不算轮次),如 10-18
#   --active-days D-D   只在这些星期内轮询(1=周一),如 1-5
#   --seed              只把游标对齐到当前最新,然后退出 0。装 watch 的第一步
#   --state-dir DIR     状态目录,默认 ~/.claude/watch/<name>
#
# probe 脚本的约定:
#   · 环境变量 PROBE_CURSOR 是当前游标(首次为空)
#   · 往 stdout 打一个 JSON 数组,每个元素至少有 `at`(可排序的游标值,如 ISO8601)
#     可选 `id`(去重用,没有就用 at + who 组合)、`kind`、以及任意你想让 agent 看到的字段
#   · 元素里出现 kind == "terminal" → 循环退出 11,agent 收尾
#   · probe 自己退出非 0 → 循环退出 12,agent 去看错误
#   · **probe 要在 shell 里把数据压成摘要**。原始分页 JSON 灌进 agent 上下文会永久留着,
#     每轮唤醒都要重新 cache-read,是复利式膨胀。用 jq 只留需要判断的字段。
#
# 退出码:
#   10  有新增项,已写进 <state>/inbox.json
#   11  命中终止条件(probe 报了 terminal)
#   12  probe 出错,详情在 <state>/signal.json 和 log。不动 inbox
#   13  跑满 max-runtime,没事发生 —— agent 应该原样重新拉起。不动 inbox
#   1   用法错误 / 同名循环仍在跑(锁被占且持锁进程存活)

set -uo pipefail

# 后台进程继承启动它的会话环境,PATH 一般没问题;补一份标准路径当兜底。
# 追加而不是前置 —— 调用方指定的 PATH 优先
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

NAME=""; PROBE=""; INTERVAL=120; MAX_RUNTIME=5400; BACKOFF=0
ACTIVE_HOURS=""; ACTIVE_DAYS=""; SEED=0; STATE_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --name)        NAME="$2"; shift 2 ;;
    --probe)       PROBE="$2"; shift 2 ;;
    --interval)    INTERVAL="$2"; shift 2 ;;
    --max-runtime) MAX_RUNTIME="$2"; shift 2 ;;
    --backoff)     BACKOFF=1; shift ;;
    --active)      ACTIVE_HOURS="$2"; shift 2 ;;
    --active-days) ACTIVE_DAYS="$2"; shift 2 ;;
    --seed)        SEED=1; shift ;;
    --state-dir)   STATE_DIR="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "找不到 jq —— 本脚本全程依赖它。https://jqlang.github.io/jq/" >&2; exit 1; }

# 非数字的 --interval 会让 sleep 每轮立刻失败 —— 循环满速空转,永不退出也永不唤醒 agent,
# 正好是本项目宣称的「唯一不告警的失效方式」。非数字的 --max-runtime 则让 exit 13 那道
# 安全网静默失效。两个都必须在启动前挡住。
for pair in "INTERVAL:--interval:$INTERVAL" "MAX_RUNTIME:--max-runtime:$MAX_RUNTIME"; do
  flag=$(echo "$pair" | cut -d: -f2); val=$(echo "$pair" | cut -d: -f3)
  case "$val" in
    ''|*[!0-9]*) echo "$flag 必须是正整数,收到: '$val'" >&2; exit 1 ;;
    0)           echo "$flag 不能是 0" >&2; exit 1 ;;
  esac
done

[ -n "$NAME" ]  || { echo "--name required" >&2; exit 1; }
[ -n "$PROBE" ] || { echo "--probe required" >&2; exit 1; }
[ -x "$PROBE" ] || { echo "probe not executable: $PROBE" >&2; exit 1; }

STATE_DIR="${STATE_DIR:-$HOME/.claude/watch/$NAME}"
mkdir -p "$STATE_DIR"
CURSOR_F="$STATE_DIR/cursor"; INBOX="$STATE_DIR/inbox.json"
SIGNAL="$STATE_DIR/signal.json"
LOG="$STATE_DIR/log"; LOCK="$STATE_DIR/lock"; META="$STATE_DIR/meta.json"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# 同名 watch 只允许一个循环,否则两个都在推游标、事件会互相吃掉
if ! mkdir "$LOCK" 2>/dev/null; then
  holder=$(cat "$LOCK/pid" 2>/dev/null || echo "?")
  if [ "$holder" != "?" ] && kill -0 "$holder" 2>/dev/null; then
    log "已有循环在跑 (pid $holder),本次不启动"
    echo "watch '$NAME' already running (pid $holder)" >&2
    exit 1
  fi
  log "接管过期锁 (原 pid $holder)"
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || { echo "lock race lost" >&2; exit 1; }
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

# ---- 两个出口,严格分开 ----
# inbox.json  = 真实数据项,累积、去重,只有 agent 能清空
# signal.json = 这次为什么退出,每次覆盖
# 混在一个文件里会出两种事故:控制信号被当成数据项参与下一轮合并;
# 以及 inbox 里攒着没处理的项时被一条控制信号覆盖掉,事件永久丢失。
emit_signal_and_exit() {  # $1=exit_code  $2=json对象
  printf '%s\n' "$2" > "$SIGNAL"
  log "exit $1 (signal), inbox 保持不动"
  exit "$1"
}

emit_data_and_exit() {  # $1=exit_code  $2=json数组  $3=signal对象
  printf '%s\n' "$2" > "$INBOX"
  printf '%s\n' "$3" > "$SIGNAL"
  log "exit $1, inbox $(printf '%s' "$2" | jq -c 'length') 项"
  exit "$1"
}

bail() {  # probe 或自身出错
  local detail="$1"
  log "FATAL: $detail"
  emit_signal_and_exit 12 "$(jq -n --arg d "$detail" --arg n "$NAME" \
    '{kind:"guard-error", watch:$n, detail:$d}')"
}

in_active_window() {
  [ -z "$ACTIVE_HOURS" ] && [ -z "$ACTIVE_DAYS" ] && return 0
  if [ -n "$ACTIVE_DAYS" ]; then
    local dow; dow=$(date +%u)
    local d1=${ACTIVE_DAYS%-*} d2=${ACTIVE_DAYS#*-}
    [ "$dow" -ge "$d1" ] && [ "$dow" -le "$d2" ] || return 1
  fi
  if [ -n "$ACTIVE_HOURS" ]; then
    local h; h=$(date +%H); h=${h#0}; h=${h:-0}
    local h1=${ACTIVE_HOURS%-*} h2=${ACTIVE_HOURS#*-}
    [ "$h" -ge "$h1" ] && [ "$h" -lt "$h2" ] || return 1
  fi
  return 0
}

run_probe() {  # stdout = items json array
  local cursor; cursor=$(cat "$CURSOR_F" 2>/dev/null || echo "")
  local out rc
  out=$(PROBE_CURSOR="$cursor" "$PROBE" 2>>"$LOG"); rc=$?
  [ $rc -ne 0 ] && { echo "__PROBE_FAILED__ rc=$rc"; return 1; }
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || { echo "__PROBE_FAILED__ 输出不是 JSON 数组"; return 1; }
  printf '%s' "$out"
  return 0
}

cat > "$META" <<EOF
{"name":"$NAME","probe":"$PROBE","interval":$INTERVAL,"max_runtime":$MAX_RUNTIME,
 "pid":$$,"started_at":"$(date -u '+%FT%TZ')"}
EOF

# ---- seed: 只对齐游标,不叫醒 agent ----
if [ "$SEED" = "1" ]; then
  items=$(run_probe) || { echo "$items" >&2; bail "seed 时 probe 失败: $items"; }
  latest=$(printf '%s' "$items" | jq -r 'sort_by(.at) | .[-1].at // ""')
  printf '%s' "$latest" > "$CURSOR_F"
  printf '[]\n' > "$INBOX"
  log "seeded cursor=$latest"
  echo "seeded '$NAME' cursor=$latest"
  exit 0
fi

log "循环启动 pid=$$ interval=${INTERVAL}s max_runtime=${MAX_RUNTIME}s backoff=$BACKOFF"
started=$(date +%s); cur_interval=$INTERVAL

while true; do
  now=$(date +%s)
  if [ $((now - started)) -ge "$MAX_RUNTIME" ]; then
    log "跑满 ${MAX_RUNTIME}s,交回 agent 重新拉起"
    emit_signal_and_exit 13 "$(jq -n --arg n "$NAME" --arg s "$MAX_RUNTIME" \
      '{kind:"max-runtime", watch:$n, ran_seconds:($s|tonumber)}')"
  fi

  if in_active_window; then
    items=$(run_probe) || bail "probe 失败: $items"

    cursor=$(cat "$CURSOR_F" 2>/dev/null || echo "")
    fresh=$(printf '%s' "$items" | jq --arg c "$cursor" \
      '[ .[] | select(($c == "") or (.at > $c)) ] | sort_by(.at)')
    n=$(printf '%s' "$fresh" | jq 'length')

    if [ "$n" -gt 0 ]; then
      # 跟 inbox 里没处理完的旧项合并。控制信号不该出现在 inbox 里,这里再防一手。
      # kind 用 tostring 兜一下:probe 完全可以吐一个非字符串的 kind,而 test() 遇到
      # 非字符串会直接报错 —— 那会走到下面的 bail,而不是悄悄把 inbox 清空。
      old=$(cat "$INBOX" 2>/dev/null); [ -z "$old" ] && old='[]'
      printf '%s' "$old" | jq -e 'type == "array"' >/dev/null 2>&1 \
        || bail "inbox.json 不是合法 JSON 数组,拒绝覆盖它(里面可能还有没处理的项)"

      merged=$(jq -n --argjson a "$old" --argjson b "$fresh" '
        ($a + $b)
        | map(select(((.kind // "") | tostring) | test("^(max-runtime|guard-error)$") | not))
        | unique_by(.id // [.who?, .at]) | sort_by(.at)') \
        || bail "合并 inbox 失败,inbox 和游标都保持不动"
      [ -n "$merged" ] || bail "合并结果为空字符串,inbox 和游标都保持不动"

      latest=$(printf '%s' "$fresh" | jq -er '.[-1].at') \
        || bail "取不到本轮最大的 at,游标不推进"

      # 先落盘 inbox 再推游标 —— 顺序反了的话中途挂掉会永久丢事件
      printf '%s\n' "$merged" > "$INBOX"
      printf '%s' "$latest" > "$CURSOR_F"

      if printf '%s' "$fresh" | jq -e 'any(.kind == "terminal")' >/dev/null 2>&1; then
        log "probe 报了 terminal"
        emit_data_and_exit 11 "$merged" \
          "$(jq -n --arg n "$NAME" '{kind:"terminal", watch:$n}')"
      fi

      log "$n 项新增,唤醒 agent"
      emit_data_and_exit 10 "$merged" \
        "$(jq -n --arg n "$NAME" --argjson c "$n" '{kind:"new-items", watch:$n, count:$c}')"
    fi

    [ "$BACKOFF" = "1" ] && [ "$cur_interval" -lt $((INTERVAL * 8)) ] \
      && cur_interval=$((cur_interval * 2))
    log "无变化,睡 ${cur_interval}s"
  else
    log "活动窗口外,睡 ${INTERVAL}s"
    cur_interval=$INTERVAL
  fi

  sleep "$cur_interval"
done
