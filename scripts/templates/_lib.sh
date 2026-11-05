#!/bin/bash
# 模板共用小库。被 probe-*.sh source。
#
# 提供这些:
#   require_bin CMD...  —— 缺命令时点名报错,并给安装地址
#   require_env NAME... —— 缺参数时清晰报错退出(会变成循环的 exit 12,详情进 log)
#   run_with_timeout S cmd... —— 可移植超时。macOS 默认没有 timeout(1),没有就用看门狗兜底
#   fetch_with_retry S cmd... —— 在上面基础上重试,专治一次性网络抖动
#   default_bot_re —— 常见 bot 账号的正则,可用 BOT_RE 覆盖
#   agent_prefixes_json / AGENT_JQ_DEF —— 「自己」只按 agent 前缀认,见文件末尾

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
  local tmp rc pid wd had_m=0
  tmp=$(mktemp)
  # 只 kill 外层子 shell 的话,命令自己起的子进程(比如 claude -p)会留下来继续挂着。
  # 打开 job control 后每个后台任务自成一个进程组,超时时按组杀,连带杀掉它的全部子孙
  case $- in *m*) had_m=1 ;; esac
  set -m
  ( "$@" >"$tmp" 2>/dev/null ) & pid=$!
  ( sleep "$secs"; kill -9 -- "-$pid" 2>/dev/null ) >/dev/null 2>&1 & wd=$!
  [ "$had_m" = "1" ] || set +m
  wait "$pid" 2>/dev/null; rc=$?
  kill -- "-$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  cat "$tmp"; rm -f "$tmp"
  return $rc
}

# 一次网络抖动不该把整个循环打死。probe 失败 = 循环 exit 12 = 唤醒 agent 让它来修,
# 而唤醒是这套机制里唯一贵的东西 —— 为一次瞬时失败付这个代价不划算。
#
# 重试只在「取数失败」这一步做,不碰游标:拿不到数据就重试,拿到了才往下走。所以重试
# 不会让循环静默跳过事件,只是不为抖动叫醒你。真正的坏配置(token 过期、频道 ID 写错)
# 每次都失败,重试完照样 exit 12,该报的还是会报,只是晚 RETRY_SLEEP*N 秒。
#
# 只按退出码判失败,不看输出是否为空 —— 空输出常常是合法结果(还没有人 review 的 PR、
# 空 thread),当成失败会把它重试到超时再判整个 probe 失败。要不要接受空输出由调用方
# 自己判断,它才知道这个 endpoint 空着正不正常。
#
# 次数与间隔可用 RETRY_TIMES / RETRY_SLEEP 覆盖;默认 3 次、间隔 5 秒。
fetch_with_retry() {
  local secs="$1"; shift
  local times="${RETRY_TIMES:-3}" gap="${RETRY_SLEEP:-5}"
  local attempt=1 out rc
  while :; do
    out=$(run_with_timeout "$secs" "$@"); rc=$?
    if [ $rc -eq 0 ]; then
      printf '%s' "$out"
      return 0
    fi
    [ "$attempt" -ge "$times" ] && break
    echo "取数失败(rc=$rc),第 $attempt/$times 次,${gap}s 后重试: $1" >&2
    sleep "$gap"
    attempt=$((attempt + 1))
  done
  printf '%s' "$out"
  return "${rc:-1}"
}

# `[bot]` 后缀覆盖了 GitHub App;web-flow 是 GitHub 网页端 merge commit 的作者
default_bot_re='\[bot\]$|^web-flow$'

# ---------- 过滤自己:只按 agent 前缀认,不按账号 ----------
# agent 往往用你本人的账号发言(Slack / GitHub 都是),所以账号分不出这句话是谁说的。
# 规则只有一条,所有模板一样:
#   SELF 名下、以 agent 前缀开头的 → agent 代发的,滤掉(否则自己把自己叫醒,死循环)
#   SELF 名下、不带前缀的          → 你本人手打的,留着,照样叫醒 agent
#   别人发的                       → 一律留着,哪怕引用了带前缀的话
# 没有「SELF 发的全滤掉」这条路:那样会把本人在 thread / PR 里的回复一起吃掉,而且没有任何迹象。
#
# 配置(环境变量):
#   AGENT_PREFIX   agent 前缀,默认 '[ 🐶 Claude:]'。去掉开头空白后按字面 startswith 匹配。
#                  前缀里的 🐶 和 :dog: 两种写法都认 —— Slack 会把 emoji 存成 :shortcode:
#   AGENT_MARK     旧名,等于 AGENT_PREFIX(两个都给时 AGENT_PREFIX 优先)
#   AGENT_MARK_RE  可选,额外一条正则,命中也算 agent 代发(前缀里有别的 emoji 时用)
#   SELF_KEEP_HUMAN 已废弃:本人手打的现在总是保留。旧配置里留着也不报错,直接忽略
#
# 用法(jq 里):
#   jq --argjson prefixes "$(agent_prefixes_json)" --arg markre "${AGENT_MARK_RE:-}" \
#      "$AGENT_JQ_DEF"'... | select(.user != $self or (.text | is_agent($prefixes; $markre) | not))'
agent_prefixes_json() {
  jq -cn --arg p "${AGENT_PREFIX:-${AGENT_MARK:-[ 🐶 Claude:]}}" \
    '[$p, ($p | split("🐶") | join(":dog:")), ($p | split(":dog:") | join("🐶"))] | unique'
}
AGENT_JQ_DEF='def is_agent($prefixes; $re):
  (. // "") as $raw | ($raw | sub("^\\s+"; "")) as $t
  | any($prefixes[]; . as $p | $t | startswith($p))
    or ($re != "" and ($raw | test($re))); '
