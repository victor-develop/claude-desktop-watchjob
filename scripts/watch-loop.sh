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
#   --max-runtime N     最长跑多久(秒),到点退出 13 让 agent 重新拉起,默认 259200(3 天)。
#                       注意 Claude Code 的后台 Bash 最多活 2 小时(timeout 上限 7200000ms),
#                       要跑满 3 天必须配 --daemon 脱离 harness 跑,见下
#   --daemon            守护模式:有新增项只写 inbox + 刷新 <state>/wake,不退出,继续轮询;
#                       probe 出错只记 log、下一轮重试,连续失败 3 次(WATCH_DAEMON_FAIL_ALERT)才写 signal + 刷新 wake。用 nohup 脱离 harness 启动,
#                       再用 watch-wait.sh(run_in_background)等 wake 叫醒 agent
#   --relay             直接投递模式(隐含 --daemon):有事时用 watch-relay.sh 把通知直接投递进
#                       WATCH_TARGET_SESSION_LINK 指定的 Desktop 会话,不需要 watch-wait.sh。投递失败的通知
#                       落 <state>/relay-pending.json,每轮轮询时重投(间隔不短于 WATCH_RELAY_RETRY 秒,默认 60)。
#                       terminal、max-runtime、致命错误这类退出前的通知会一直重投到成功才退出。
#                       目标会话、唤醒链接等配置见 watch-relay.sh 顶部注释
#   --relay-permission-mode M  投递进程的权限模式(写进 WATCH_RELAY_PERMISSION_MODE),默认 auto。
#                       要和目标会话一致,不一致时通知会被 Desktop 挂起等人批准,而循环以为已送达
#   --backoff           连续无事时间隔翻倍,上限 interval*8。适合低频源
#   --active HH-HH      只在这个小时区间内轮询,窗口外空转(不算轮次),如 10-18
#   --active-days D-D   只在这些星期内轮询(1=周一),如 1-5
#   --seed              只把游标对齐到当前最新,然后退出 0。装 watch 的第一步
#   --state-dir DIR     状态目录,默认 ~/.claude/watch/<name>。显式给这个参数 = 你确认
#                       该目录可以被本脚本写入和清理
#
# --name 必须是单个路径组件(字母数字开头,只含 [A-Za-z0-9._-]):它拼进状态目录路径,
# 脚本会往里写文件、递归删 lock,带 / 或 .. 的名字会被拒绝。
# 游标存两个文件:cursor(最新 at)+ cursor_ids(at 恰好等于游标的已见条目键)——
# 秒级时间戳下同秒晚到的条目靠后者去重投递,不会被 > 比较永久漏掉。
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

NAME=""; PROBE=""; INTERVAL=120; MAX_RUNTIME=259200; BACKOFF=0; DAEMON=0; RELAY=0
ACTIVE_HOURS=""; ACTIVE_DAYS=""; SEED=0; STATE_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --name)        NAME="$2"; shift 2 ;;
    --probe)       PROBE="$2"; shift 2 ;;
    --interval)    INTERVAL="$2"; shift 2 ;;
    --max-runtime) MAX_RUNTIME="$2"; shift 2 ;;
    --backoff)     BACKOFF=1; shift ;;
    --daemon)      DAEMON=1; shift ;;
    --relay)       RELAY=1; DAEMON=1; shift ;;
    --relay-permission-mode) export WATCH_RELAY_PERMISSION_MODE="$2"; shift 2 ;;
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

RELAY_CMD="${WATCH_RELAY_CMD:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/watch-relay.sh}"
RELAY_RETRY="${WATCH_RELAY_RETRY:-60}"
if [ "$RELAY" = "1" ] && [ "$SEED" = "0" ]; then
  [ -x "$RELAY_CMD" ] || { echo "投递脚本不可执行: $RELAY_CMD" >&2; exit 1; }
  # 配置错了要在启动时报,而不是等到第一次有事、投递一直失败才发现
  "$RELAY_CMD" --check || exit 1
  case "$RELAY_RETRY" in ''|*[!0-9]*|0) echo "WATCH_RELAY_RETRY 必须是正整数,收到: '$RELAY_RETRY'" >&2; exit 1 ;; esac
fi

# NAME 会拼进状态目录路径,而脚本会往里写文件、递归删 lock —— 必须是单个安全的路径组件,
# 否则 --name '../../x' 能把写入和删除逃逸到任意目录
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
  || { echo "--name 必须是字母数字开头、只含 [A-Za-z0-9._-] 的单个路径组件(≤64 字符),收到: '$NAME'" >&2; exit 1; }

STATE_DIR="${STATE_DIR:-$HOME/.claude/watch/$NAME}"
mkdir -p "$STATE_DIR"
CURSOR_F="$STATE_DIR/cursor"; CURSOR_IDS="$STATE_DIR/cursor_ids"; INBOX="$STATE_DIR/inbox.json"
SIGNAL="$STATE_DIR/signal.json"; RELAY_PENDING="$STATE_DIR/relay-pending.json"
LOG="$STATE_DIR/log"; LOCK="$STATE_DIR/lock"; META="$STATE_DIR/meta.json"; WAKE="$STATE_DIR/wake"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# inbox 的锁和原子写,和 watch-ack.sh 共用一份实现
# shellcheck source=inbox-lock.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/inbox-lock.sh"
INBOX_LOCKED=0; RELAY_ARMED=0; RELAY_FINAL_SENT=0

# 同名 watch 只允许一个循环,否则两个都在推游标、事件会互相吃掉。
# 接管过期锁必须原子:直接 rm -rf + mkdir 的话,两个启动者可能都判定旧 pid 已死,
# 后到者会把先到者刚建好的锁删掉,双方并发跑起来。改用 rename(2):mv 只有一个赢家,
# 输家回到 mkdir 竞争(同样原子),任何交错下最多一个进程持锁。
if ! mkdir "$LOCK" 2>/dev/null; then
  holder=$(cat "$LOCK/pid" 2>/dev/null || echo "?")
  if [ "$holder" != "?" ] && kill -0 "$holder" 2>/dev/null; then
    log "已有循环在跑 (pid $holder),本次不启动"
    echo "watch '$NAME' already running (pid $holder)" >&2
    exit 1
  fi
  # 移走前重读:上面判定死锁到这里之间,锁可能已被并发接管者换成了活锁
  holder2=$(cat "$LOCK/pid" 2>/dev/null || echo "?")
  if [ "$holder2" != "?" ] && kill -0 "$holder2" 2>/dev/null; then
    echo "lock race lost (now held by live pid $holder2)" >&2; exit 1
  fi
  stale="$LOCK.stale.$$"
  if mv "$LOCK" "$stale" 2>/dev/null; then rm -rf "$stale"; fi
  mkdir "$LOCK" 2>/dev/null || { echo "lock race lost" >&2; exit 1; }
  log "接管过期锁 (原 pid $holder)"
fi
echo $$ > "$LOCK/pid"
# 写完 pid 再验一次所有权:极端交错下(慢一步的接管者刚好在上面两步之间通过了死锁判定)
# 自己的新锁可能被移走。settle 一拍后 pid 不是自己 → 退出,让对方独占
sleep 1
[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] \
  || { echo "lock ownership lost right after acquire" >&2; exit 1; }

# ---- 两个出口,严格分开 ----
# inbox.json  = 真实数据项,累积、去重;只有 agent 能删(用 watch-ack.sh 按 id 删),写之前都要拿 inbox 锁
# signal.json = 这次为什么退出,每次覆盖
# 混在一个文件里会出两种事故:控制信号被当成数据项参与下一轮合并;
# 以及 inbox 里攒着没处理的项时被一条控制信号覆盖掉,事件永久丢失。
emit_signal_and_exit() {  # $1=exit_code  $2=json对象
  printf '%s\n' "$2" > "$SIGNAL"
  touch "$WAKE"
  relay_final "$2"
  log "exit $1 (signal), inbox 保持不动"
  exit "$1"
}

# 这两个 emit 不再写 inbox:调用前 merge 那一步已经在 inbox 锁里写好了。
# 这里再写一遍会绕过锁,把 agent 在这几毫秒里用 watch-ack.sh 删掉的项写回来
emit_data_and_exit() {  # $1=exit_code  $2=json数组(只用来记日志)  $3=signal对象
  printf '%s\n' "$3" > "$SIGNAL"
  touch "$WAKE"
  relay_final "$3"
  log "exit $1, inbox $(printf '%s' "$2" | jq -c 'length') 项"
  exit "$1"
}

# 守护模式下的「叫醒」:写 signal、刷新 wake 文件,但不退出 —— 由 watch-wait.sh 去叫 agent(inbox 已在 merge 那步写好)
emit_data_and_continue() {  # $1=json数组(只用来记日志)  $2=signal对象
  daemon_alert "$2"
  log "inbox $(printf '%s' "$1" | jq -c 'length') 项,已刷新 wake,继续轮询"
}

# 守护模式下不退出的告警:写 signal、刷新 wake;--relay 时再投递一次
daemon_alert() {  # $1=signal对象
  printf '%s\n' "$1" > "$SIGNAL"
  touch "$WAKE"
  [ "$RELAY" = "1" ] && { relay_queue "$1"; relay_flush; }
  return 0
}

# ---- 直接投递(--relay) ----
# inbox 本身就是持久的数据队列,这里只排「要告诉会话哪些事」。多条没投出去的通知合并成一次投递,
# 投递内容在投递那一刻按当前 inbox 生成,所以晚投不会漏项
relay_queue() {  # $1=signal对象;排进队列并把下次重投时间清零,让这次有事立刻尝试
  local old; old=$(cat "$RELAY_PENDING" 2>/dev/null)
  printf '%s' "$old" | jq -e '.signals | type == "array"' >/dev/null 2>&1 || old='{"signals":[]}'
  jq -cn --argjson o "$old" --argjson s "$1" '$o | .signals = ((.signals + [$s]) | .[-20:]) | .next_at = 0' \
    > "$RELAY_PENDING.tmp.$$" && mv -f "$RELAY_PENDING.tmp.$$" "$RELAY_PENDING"
}

relay_flush() {  # 0 = 没有待投递的,或者刚投递成功;1 = 还没到重投时间,或者投递失败
  [ -f "$RELAY_PENDING" ] || return 0
  local p next sigs
  p=$(cat "$RELAY_PENDING" 2>/dev/null)
  next=$(printf '%s' "$p" | jq -r '.next_at // 0' 2>/dev/null); case "$next" in ''|*[!0-9]*) next=0 ;; esac
  [ "$(date +%s)" -ge "$next" ] || return 1
  sigs=$(printf '%s' "$p" | jq -c '.signals' 2>/dev/null)
  printf '%s' "$sigs" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1 || { rm -f "$RELAY_PENDING"; return 0; }
  if "$RELAY_CMD" --name "$NAME" --state-dir "$STATE_DIR" --signals "$sigs" >>"$LOG" 2>&1; then
    rm -f "$RELAY_PENDING"
    log "已投递 $(printf '%s' "$sigs" | jq -r 'map(.kind) | unique | join(",")') 通知"
    return 0
  fi
  jq -cn --argjson s "$sigs" --argjson t "$(( $(date +%s) + RELAY_RETRY ))" '{signals:$s, next_at:$t}' \
    > "$RELAY_PENDING.tmp.$$" && mv -f "$RELAY_PENDING.tmp.$$" "$RELAY_PENDING"
  log "投递失败,${RELAY_RETRY}s 后重投(详情见上面几行)"
  return 1
}

# 循环要退出了,之后没人再重投,所以这里一直重投到成功。目标会话一直不可达时循环会停在这里,
# kill 掉即可,通知留在 relay-pending.json 里
relay_final() {  # $1=signal对象
  [ "$RELAY" = "1" ] && [ "$RELAY_ARMED" = "1" ] || return 0
  # 重投可能要很久,不能一直占着 inbox 锁,否则 watch-ack.sh 全程拿不到锁
  [ "$INBOX_LOCKED" = "1" ] && { inbox_unlock "$STATE_DIR"; INBOX_LOCKED=0; }
  RELAY_FINAL_SENT=1
  relay_queue "$1"
  until relay_flush; do nap "$RELAY_RETRY"; done
}

# sleep 放后台再 wait:前台 sleep 期间 bash 会把 TERM 推迟到 sleep 结束才处理
nap() { sleep "$1" & NAP_PID=$!; wait "$NAP_PID"; NAP_PID=""; }
NAP_PID=""

on_exit() {  # $1=退出码
  [ -n "$NAP_PID" ] && kill "$NAP_PID" 2>/dev/null
  [ "$INBOX_LOCKED" = "1" ] && inbox_unlock "$STATE_DIR"
  # 没走 emit_* 就退出(被 kill、脚本自身出错)时,尽力投递一次,让会话知道没人在盯了。只投一次、不重试
  if [ "$RELAY" = "1" ] && [ "$RELAY_ARMED" = "1" ] && [ "$RELAY_FINAL_SENT" = "0" ]; then
    relay_queue "$(jq -cn --arg n "$NAME" --arg d "退出码 $1" '{kind:"loop-exit", watch:$n, detail:$d}')"
    relay_flush
  fi
  # 释放只删自己的锁:长轮次结束时锁可能已被合法接管,不能连别人的一起删
  [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"
}
trap 'on_exit $?' EXIT
# 默认处置下收到这几个信号会直接死掉、不走 EXIT trap;转成 exit 才能释放锁、发出 loop-exit 通知
trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP

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
{"name":"$NAME","probe":"$PROBE","interval":$INTERVAL,"max_runtime":$MAX_RUNTIME,"daemon":$DAEMON,
 "pid":$$,"started_at":"$(date -u '+%FT%TZ')"}
EOF

# 一个条目的去重键:有 id 用 id,没有用 who|at。跟下面 inbox 合并的 unique_by 保持同一套语义
KEYX='(.id // ((.who // "") + "|" + (.at | tostring)))'

# 游标是秒级时间戳时,同一秒内、拉取之后才出现的条目会满足 .at == cursor 而被 > 过滤掉,
# 且永远不再重试。所以游标旁边存一份 cursor_ids:已见过的、at 恰好等于游标的条目键。
# 过滤规则变成:at > cursor,或 at == cursor 且键不在 cursor_ids 里 —— 边界条目至少投递一次。
cursor_ids_at() {  # $1=items数组 $2=at值 → 该时刻所有条目的键
  printf '%s' "$1" | jq -c --arg l "$2" "[ .[] | select(.at == \$l) | $KEYX ]"
}

# ---- seed: 只对齐游标,不叫醒 agent ----
if [ "$SEED" = "1" ]; then
  items=$(run_probe) || { echo "$items" >&2; bail "seed 时 probe 失败: $items"; }
  latest=$(printf '%s' "$items" | jq -r 'sort_by(.at) | .[-1].at // ""')
  cursor_ids_at "$items" "$latest" > "$CURSOR_IDS"
  printf '%s' "$latest" > "$CURSOR_F"
  inbox_lock "$STATE_DIR" || { echo "拿不到 inbox 锁,seed 中止" >&2; exit 1; }
  INBOX_LOCKED=1; inbox_write "$INBOX" '[]'; inbox_unlock "$STATE_DIR"; INBOX_LOCKED=0
  log "seeded cursor=$latest"
  echo "seeded '$NAME' cursor=$latest"
  exit 0
fi

log "循环启动 pid=$$ interval=${INTERVAL}s max_runtime=${MAX_RUNTIME}s backoff=$BACKOFF daemon=$DAEMON relay=$RELAY"
RELAY_ARMED=1
started=$(date +%s); cur_interval=$INTERVAL; probe_fails=0; lock_fails=0; DAEMON_FAIL_ALERT=${WATCH_DAEMON_FAIL_ALERT:-3}

while true; do
  [ "$RELAY" = "1" ] && relay_flush
  now=$(date +%s)
  if [ $((now - started)) -ge "$MAX_RUNTIME" ]; then
    log "跑满 ${MAX_RUNTIME}s,交回 agent 重新拉起"
    emit_signal_and_exit 13 "$(jq -n --arg n "$NAME" --arg s "$MAX_RUNTIME" \
      '{kind:"max-runtime", watch:$n, ran_seconds:($s|tonumber)}')"
  fi

  if in_active_window; then
    if ! items=$(run_probe); then
      if [ "$DAEMON" = "1" ]; then
        # 守护模式:网络抖动不该让一个要跑 3 天的循环死掉,下一轮照常重试。单次失败只记 log;
        # 连续失败到 DAEMON_FAIL_ALERT 次才写 signal、刷新 wake 叫醒 agent —— 偶发抖动不值得一次唤醒,
        # 持续性故障(凭证过期、接口改了)才需要人看
        probe_fails=$((probe_fails + 1))
        log "probe 失败(守护模式,连续第 ${probe_fails} 次,下一轮重试): $items"
        if [ "$probe_fails" -eq "$DAEMON_FAIL_ALERT" ]; then
          daemon_alert "$(jq -n --arg d "连续 $probe_fails 次 probe 失败: $items" --arg n "$NAME" '{kind:"guard-error", watch:$n, detail:$d}')"
        fi
        nap "$cur_interval"
        continue
      fi
      bail "probe 失败: $items"
    fi
    probe_fails=0

    cursor=$(cat "$CURSOR_F" 2>/dev/null || echo "")
    seen=$(cat "$CURSOR_IDS" 2>/dev/null); [ -z "$seen" ] && seen='[]'
    printf '%s' "$seen" | jq -e 'type == "array"' >/dev/null 2>&1 || seen='[]'
    fresh=$(printf '%s' "$items" | jq --arg c "$cursor" --argjson seen "$seen" \
      "[ .[] | select((\$c == \"\") or (.at > \$c)
                     or ((.at == \$c) and ((($KEYX) as \$k | \$seen | index(\$k)) | not)))
       ] | sort_by(.at)")
    n=$(printf '%s' "$fresh" | jq 'length')

    if [ "$n" -gt 0 ]; then
      # 跟 inbox 里没处理完的旧项合并。控制信号不该出现在 inbox 里,这里再防一手。
      # kind 用 tostring 兜一下:probe 完全可以吐一个非字符串的 kind,而 test() 遇到
      # 非字符串会直接报错 —— 那会走到下面的 bail,而不是悄悄把 inbox 清空。
      # 读改写 inbox 全程持锁,和 watch-ack.sh 互斥
      if ! inbox_lock "$STATE_DIR"; then
        # 游标没推进,下一轮会把同一批项再拿到,不会丢。但一直拿不到锁就等于新项永远进不了
        # inbox、agent 永远不会被叫醒 —— 和 probe 失败一样,连续到阈值就写 signal 叫人
        if [ "$DAEMON" = "1" ]; then
          lock_fails=$((lock_fails + 1))
          log "拿不到 inbox 锁(连续第 ${lock_fails} 次),本轮跳过、下一轮重试"
          if [ "$lock_fails" -eq "$DAEMON_FAIL_ALERT" ]; then
            daemon_alert "$(jq -n --arg d "连续 $lock_fails 次拿不到 inbox 锁,看看 $STATE_DIR/inbox.lock 是不是残留" --arg n "$NAME" '{kind:"guard-error", watch:$n, detail:$d}')"
          fi
          nap "$cur_interval"; continue
        fi
        bail "拿不到 inbox 锁(watch-ack.sh 卡住了?),本轮不写 inbox、游标不推进"
      fi
      lock_fails=0
      INBOX_LOCKED=1
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

      # 游标没动(新条目和游标同秒)时,已见键要和旧的合并 —— probe 做了服务端过滤的话,
      # 本轮结果里可能不含之前见过的同秒条目,直接覆盖会把它们再投一遍
      if [ "$latest" = "$cursor" ]; then
        new_seen=$(jq -cn --argjson a "$seen" --argjson b "$(cursor_ids_at "$items" "$latest")" '$a + $b | unique')
      else
        new_seen=$(cursor_ids_at "$items" "$latest")
      fi

      # 先落盘 inbox,再推 cursor_ids 和游标 —— 顺序反了的话中途挂掉会永久丢事件;
      # 现在这个顺序下中途挂掉最多重复投递,由 inbox 的 unique_by 吸收
      inbox_lock_owned "$STATE_DIR" || bail "inbox 锁在读改写途中被接管了,本轮不写 inbox、游标不推进"
      inbox_write "$INBOX" "$merged" || bail "写 inbox 失败,游标不推进"
      inbox_unlock "$STATE_DIR"; INBOX_LOCKED=0
      printf '%s\n' "$new_seen" > "$CURSOR_IDS"
      printf '%s' "$latest" > "$CURSOR_F"

      if printf '%s' "$fresh" | jq -e 'any(.kind == "terminal")' >/dev/null 2>&1; then
        log "probe 报了 terminal"
        emit_data_and_exit 11 "$merged" \
          "$(jq -n --arg n "$NAME" '{kind:"terminal", watch:$n}')"
      fi

      sig_new=$(jq -n --arg n "$NAME" --argjson c "$n" '{kind:"new-items", watch:$n, count:$c}')
      if [ "$DAEMON" = "1" ]; then
        emit_data_and_continue "$merged" "$sig_new"
        cur_interval=$INTERVAL
        nap "$cur_interval"
        continue
      fi
      log "$n 项新增,唤醒 agent"
      emit_data_and_exit 10 "$merged" "$sig_new"
    fi

    # 先睡再翻倍。顺序反了的话 --backoff 一启动就把第一轮空闲睡成 2x,用户配的
    # --interval 从头到尾没生效过 —— 「连续无事才翻倍」里第一次空闲不算「连续」。
    log "无变化,睡 ${cur_interval}s"
    [ "$BACKOFF" = "1" ] && [ "$cur_interval" -lt $((INTERVAL * 8)) ] \
      && cur_interval=$((cur_interval * 2))
  else
    log "活动窗口外,睡 ${INTERVAL}s"
    cur_interval=$INTERVAL
  fi

  nap "$cur_interval"
done
