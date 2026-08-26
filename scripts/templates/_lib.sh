#!/bin/bash
# 模板共用小库。被 probe-*.sh source。
#
# 提供四样:
#   require_bin CMD...  —— 缺命令时点名报错,并给安装地址
#   require_env NAME... —— 缺参数时清晰报错退出(会变成循环的 exit 12,详情进 log)
#   run_with_timeout S cmd... —— 可移植超时。macOS 默认没有 timeout(1),没有就用看门狗兜底
#   default_bot_re —— 常见 bot 账号的正则,可用 BOT_RE 覆盖

# 追加而不是前置:调用方自己的 PATH 优先,标准路径只当兜底
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# 用到的命令必须先确认存在。缺了就早退并说清楚缺哪个,
# 而不是让脚本半路 command not found、吐半个数组出去
require_bin() {
  local missing=()
  for b in "$@"; do
    command -v "$b" >/dev/null 2>&1 || missing+=("$b")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "缺少必需的命令: ${missing[*]}" >&2
    for b in "${missing[@]}"; do
      case "$b" in
        gh)       echo "  gh —— GitHub CLI,https://cli.github.com(装完要 gh auth login)" >&2 ;;
        slackcli) echo "  slackcli —— https://github.com/shaharia-lab/slackcli" >&2 ;;
        jq)       echo "  jq —— https://jqlang.github.io/jq/" >&2 ;;
        curl)     echo "  curl —— 系统自带,PATH 里找不到说明环境不对" >&2 ;;
      esac
    done
    exit 2
  fi
}

require_env() {
  local missing=()
  for v in "$@"; do
    [ -z "${!v:-}" ] && missing+=("$v")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "缺少必需的环境变量: ${missing[*]}" >&2
    echo "用法见本文件顶部注释。" >&2
    exit 2
  fi
}

# 挂死的 probe 是这套机制里唯一不告警的失效方式 —— 循环永远不退出,也就永远不唤醒 agent。
# 所有网络调用都必须包一层。
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1;  then timeout  "$secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi
  local tmp rc pid wd
  tmp=$(mktemp)
  ( "$@" >"$tmp" 2>/dev/null ) & pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 & wd=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$wd" 2>/dev/null
  cat "$tmp"; rm -f "$tmp"
  return $rc
}

# `[bot]` 后缀覆盖了 GitHub App;web-flow 是 GitHub 网页端 merge commit 的作者
default_bot_re='\[bot\]$|^web-flow$'
