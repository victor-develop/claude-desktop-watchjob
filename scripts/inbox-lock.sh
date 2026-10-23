#!/bin/bash
# inbox.json 的互斥锁和原子写,watch-loop.sh 和 watch-ack.sh 共用(source 进来,不单独执行)。
#
# 为什么要锁:循环往 inbox 里 merge 新项,agent 处理完要把处理过的项删掉。两边都是
# 「读 → 改 → 写回」,不加锁时谁后写谁赢 —— agent 后写,会把循环刚 merge 进来的新项抹掉
# (事件永久丢失);循环后写,会把 agent 刚删掉的项写回来(重复叫醒)。
#
# 锁是 mkdir 出来的目录 <state>/inbox.lock,里面记着持锁进程的 pid,只在「读改写」那一瞬间持有。
# 持锁进程意外死掉时,锁目录超过 WATCH_INBOX_LOCK_STALE 秒(默认 30)就当过期接管 ——
# 正常持锁不会超过一秒。

# 只输出一行数字:GNU stat 的 -f 是「文件系统信息」,不能先试 BSD 写法
_inbox_mtime() {
  local t
  t=$(stat -c %Y "$1" 2>/dev/null) || t=$(stat -f %m "$1" 2>/dev/null) || t=0
  t=$(printf '%s' "$t" | head -n1)
  case "$t" in ''|*[!0-9]*) t=0 ;; esac
  echo "$t"
}

# 用法:inbox_lock <state_dir>;拿不到锁(等满 WATCH_INBOX_LOCK_TIMEOUT 秒,默认 20)返回 1
inbox_lock() {
  local d="$1/inbox.lock" waited=0 max="${WATCH_INBOX_LOCK_TIMEOUT:-20}" stale="${WATCH_INBOX_LOCK_STALE:-30}"
  while ! mkdir "$d" 2>/dev/null; do
    if [ -d "$d" ] && [ $(( $(date +%s) - $(_inbox_mtime "$d") )) -gt "$stale" ]; then
      # 过期接管要二级互斥:两个等锁的进程可能同时判定过期,没有这一层的话,慢的那个会把
      # 快的那个刚建好的活锁当成旧锁挪走。拿到 takeover 后重新判一次是否过期,再挪
      if mkdir "$d.takeover" 2>/dev/null; then
        if [ -d "$d" ] && [ $(( $(date +%s) - $(_inbox_mtime "$d") )) -gt "$stale" ]; then
          mv "$d" "$d.stale.$$" 2>/dev/null && rm -rf "$d.stale.$$"
        fi
        rmdir "$d.takeover" 2>/dev/null
        continue
      fi
      # takeover 自己也可能是残留(接管者在中间被杀),同样按过期处理
      [ $(( $(date +%s) - $(_inbox_mtime "$d.takeover") )) -gt "$stale" ] && rmdir "$d.takeover" 2>/dev/null
    fi
    [ "$waited" -ge $(( max * 10 )) ] && return 1
    sleep 0.1; waited=$((waited + 1))
  done
  echo $$ > "$d/pid"
}

# 锁还是不是自己的(写 inbox 之前核一次:极端情况下锁可能已被当成过期接管)
inbox_lock_owned() { [ "$(cat "$1/inbox.lock/pid" 2>/dev/null)" = "$$" ]; }

# 只释放自己的锁,不连别人的一起删
inbox_unlock() { inbox_lock_owned "$1" && rm -rf "$1/inbox.lock"; return 0; }

# 用法:inbox_write <inbox_path> <json>;先写临时文件再 mv,读的一方不会读到写了一半的文件
inbox_write() {
  local tmp="$1.tmp.$$"
  printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$1"
}
