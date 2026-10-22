#!/bin/bash
# 守护模式的叫醒器:等 watch-loop.sh --daemon 写下的 wake / inbox,有事就退出叫醒 agent。
#
# 为什么要拆成两半:Claude Code 的后台 Bash 最多活 2 小时(timeout 上限 7200000ms),
# 到点会被 harness 直接杀掉。轮询循环要跑几天,就只能脱离 harness(nohup)跑;但脱离了
# harness 的进程退出时叫不醒 agent。所以由本脚本留在 harness 里当「门铃」:
# 只读本地文件、不碰网络,接近 2 小时就主动退出 13,让 agent 原样重挂 —— 循环本身不受影响。
#
# 用法(Bash 工具 run_in_background: true, timeout: 7200000):
#   watch-wait.sh --name <名字> [--name <名字2> ...] [--timeout 秒,默认 6600]
#   一个叫醒器可以同时等多个守护循环(--name 可重复),少占一个后台任务、少一次 2 小时重挂。
#   退出时 stdout 第一行写明是哪个 watch
#
# 退出码:
#   10  inbox.json 里有待处理项(agent 处理完要把 inbox 写成 [],再重挂本脚本)
#   11  循环报了 terminal(signal.json kind=terminal),收尾,不用再挂
#   12  循环报了 probe 出错(signal.json kind=guard-error,且是本次等待期间写的)。循环还活着、会自己重试;
#       agent 看一眼 detail,确认不是持续性故障后重挂本脚本
#   13  等满 --timeout,没事 —— 原样重挂本脚本,不用汇报
#   14  守护循环不在了(锁里的 pid 已死)—— 看 signal.json / log,修好后用 nohup 重新拉起循环
#   1   用法错误

set -uo pipefail
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

NAMES=(); TIMEOUT=6600
while [ $# -gt 0 ]; do
  case "$1" in
    --name)      NAMES+=("$2"); shift 2 ;;
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
[ ${#NAMES[@]} -gt 0 ] || { echo "--name required" >&2; exit 1; }
for NAME in "${NAMES[@]}"; do
  [[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { echo "--name 不合法: '$NAME'" >&2; exit 1; }
  [ -d "$HOME/.claude/watch/$NAME" ] || { echo "状态目录不存在: ~/.claude/watch/$NAME(先 --seed 再起循环)" >&2; exit 1; }
done
case "$TIMEOUT" in ''|*[!0-9]*|0) echo "--timeout 必须是正整数" >&2; exit 1 ;; esac
# 超过 harness 的 2 小时上限没有意义:会被直接杀掉(状态是 killed,不是 13)
[ "$TIMEOUT" -le 7000 ] || { echo "--timeout 不能超过 7000(harness 后台命令最多 7200 秒)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "找不到 jq" >&2; exit 1; }


mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
started=$(date +%s)

while true; do
  for NAME in "${NAMES[@]}"; do
    STATE_DIR="$HOME/.claude/watch/$NAME"
    INBOX="$STATE_DIR/inbox.json"; SIGNAL="$STATE_DIR/signal.json"; LOCK="$STATE_DIR/lock"

    n=$(jq 'if type == "array" then length else 0 end' "$INBOX" 2>/dev/null || echo 0)
    [ "${n:-0}" -gt 0 ] && { echo "watch '$NAME': inbox 有 $n 项"; exit 10; }

    if [ -f "$SIGNAL" ] && [ "$(mtime "$SIGNAL")" -ge "$started" ]; then
      kind=$(jq -r '.kind // ""' "$SIGNAL" 2>/dev/null)
      case "$kind" in
        terminal)    echo "watch '$NAME': terminal"; exit 11 ;;
        guard-error) echo "watch '$NAME': probe 出错 —— $(jq -r '.detail // ""' "$SIGNAL" | head -c 300)"; exit 12 ;;
      esac
    fi

    pid=$(cat "$LOCK/pid" 2>/dev/null || echo "")
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      echo "watch '$NAME': 守护循环不在了(pid=${pid:-无})"; exit 14
    fi
  done

  [ $(( $(date +%s) - started )) -ge "$TIMEOUT" ] && exit 13
  sleep 5
done
