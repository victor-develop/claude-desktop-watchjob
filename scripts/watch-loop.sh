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

NAME=""; PROBE=""; INTERVAL=120; MAX_RUNTIME=259200; BACKOFF=0; DAEMON=0
ACTIVE_HOURS=""; ACTIVE_DAYS=""; SEED=0; STATE_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --name)        NAME="$2"; shift 2 ;;
    --probe)       PROBE="$2"; shift 2 ;;
    --interval)    INTERVAL="$2"; shift 2 ;;
    --max-runtime) MAX_RUNTIME="$2"; shift 2 ;;
    --backoff)     BACKOFF=1; shift ;;
    --daemon)      DAEMON=1; shift ;;
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

# NAME 会拼进状态目录路径,而脚本会往里写文件、递归删 lock —— 必须是单个安全的路径组件,
# 否则 --name '../../x' 能把写入和删除逃逸到任意目录
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
  || { echo "--name 必须是字母数字开头、只含 [A-Za-z0-9._-] 的单个路径组件(≤64 字符),收到: '$NAME'" >&2; exit 1; }

STATE_DIR="${STATE_DIR:-$HOME/.claude/watch/$NAME}"
mkdir -p "$STATE_DIR"
CURSOR_F="$STATE_DIR/cursor"; CURSOR_IDS="$STATE_DIR/cursor_ids"; INBOX="$STATE_DIR/inbox.json"
SIGNAL="$STATE_DIR/signal.json"
LOG="$STATE_DIR/log"; LOCK="$STATE_DIR/lock"; META="$STATE_DIR/meta.json"; WAKE="$STATE_DIR/wake"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

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
# 释放只删自己的锁:长轮次结束时锁可能已被合法接管,不能连别人的一起删
trap '[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"' EXIT
# 写完 pid 再验一次所有权:极端交错下(慢一步的接管者刚好在上面两步之间通过了死锁判定)
# 自己的新锁可能被移走。settle 一拍后 pid 不是自己 → 退出,让对方独占
sleep 1
[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] \
  || { echo "lock ownership lost right after acquire" >&2; exit 1; }

# ---- 两个出口,严格分开 ----
# inbox.json  = 真实数据项,累积、去重,只有 agent 能清空
# signal.json = 这次为什么退出,每次覆盖
# 混在一个文件里会出两种事故:控制信号被当成数据项参与下一轮合并;
# 以及 inbox 里攒着没处理的项时被一条控制信号覆盖掉,事件永久丢失。
emit_signal_and_exit() {  # $1=exit_code  $2=json对象
  printf '%s\n' "$2" > "$SIGNAL"
  touch "$WAKE"
  log "exit $1 (signal), inbox 保持不动"
  exit "$1"
}

emit_data_and_exit() {  # $1=exit_code  $2=json数组  $3=signal对象
  printf '%s\n' "$2" > "$INBOX"
  printf '%s\n' "$3" > "$SIGNAL"
  touch "$WAKE"
  log "exit $1, inbox $(printf '%s' "$2" | jq -c 'length') 项"
  exit "$1"
}

# 守护模式下的「叫醒」:写 inbox / signal、刷新 wake 文件,但不退出 —— 由 watch-wait.sh 去叫 agent
emit_data_and_continue() {  # $1=json数组  $2=signal对象
  printf '%s\n' "$1" > "$INBOX"
  printf '%s\n' "$2" > "$SIGNAL"
  touch "$WAKE"
  log "inbox $(printf '%s' "$1" | jq -c 'length') 项,已刷新 wake,继续轮询"
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
  printf '[]\n' > "$INBOX"
  log "seeded cursor=$latest"
  echo "seeded '$NAME' cursor=$latest"
  exit 0
fi

log "循环启动 pid=$$ interval=${INTERVAL}s max_runtime=${MAX_RUNTIME}s backoff=$BACKOFF daemon=$DAEMON"
started=$(date +%s); cur_interval=$INTERVAL; probe_fails=0; DAEMON_FAIL_ALERT=${WATCH_DAEMON_FAIL_ALERT:-3}

while true; do
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
          printf '%s\n' "$(jq -n --arg d "连续 $probe_fails 次 probe 失败: $items" --arg n "$NAME" '{kind:"guard-error", watch:$n, detail:$d}')" > "$SIGNAL"
          touch "$WAKE"
        fi
        sleep "$cur_interval"
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
      printf '%s\n' "$merged" > "$INBOX"
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
        sleep "$cur_interval"
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

  sleep "$cur_interval"
done
