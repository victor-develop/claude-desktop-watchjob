#!/bin/bash
# 处理完 inbox 里的项以后,用它把「处理过的那几项」从 inbox.json 里删掉。
#
# 为什么不直接 echo '[]' > inbox.json:你读 inbox、处理、清空之间可能过了好几分钟,
# 守护循环这期间照常往 inbox 里 merge 新项。整个覆盖成 [] 会把这些还没看过的新项一起抹掉,
# 而且不会有任何报错 —— 你以为处理完了,其实漏了。本脚本只删你点名的 id,和循环共用
# 一把 inbox 锁,删完告诉你还剩几项没处理。
#
# 用法:
#   watch-ack.sh --name <名字> --ids c:2107,c:2108      # 逗号分隔
#   watch-ack.sh --name <名字> --id c:2107 --id c:2108   # 或者重复 --id
#   [--state-dir 目录]   默认 ~/.claude/watch/<名字>,和 watch-loop.sh 一致
#
# 条目的 id 就是 inbox 里每一项的 .id;没有 id 的项用 "who|at" 指代(和循环去重用的键一样)。
#
# 退出码:
#   0   删完了,inbox 已经空了
#   10  删完了,但 inbox 里还有没点名的项(stdout 列出来)—— 处理完再 ack 一次
#   2   拿不到 inbox 锁(循环卡在写 inbox 里?),什么都没改,过几秒重试
#   1   用法错误 / inbox 不是合法 JSON 数组(什么都没改)
#
# 点名的 id 在 inbox 里找不到不算错(可能已经 ack 过),会在 stderr 提一句。

set -uo pipefail
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
command -v jq >/dev/null 2>&1 || { echo "找不到 jq" >&2; exit 1; }

NAME=""; STATE_DIR=""; IDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --name)      NAME="$2"; shift 2 ;;
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    --id)        [ -n "$2" ] && IDS+=("$2"); shift 2 ;;
    --ids)       IFS=',' read -r -a more <<< "$2"
                 for x in ${more[@]+"${more[@]}"}; do [ -n "$x" ] && IDS+=("$x"); done; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
[ -n "$NAME" ] || { echo "--name required" >&2; exit 1; }
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { echo "--name 不合法: '$NAME'" >&2; exit 1; }
[ ${#IDS[@]} -gt 0 ] 2>/dev/null || { echo "至少给一个 --id / --ids。要清空全部也请把 id 一个个列出来 —— 这正是本脚本要防的事" >&2; exit 1; }

STATE_DIR="${STATE_DIR:-$HOME/.claude/watch/$NAME}"
[ -d "$STATE_DIR" ] || { echo "状态目录不存在: $STATE_DIR" >&2; exit 1; }
INBOX="$STATE_DIR/inbox.json"

# shellcheck source=inbox-lock.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/inbox-lock.sh"

inbox_lock "$STATE_DIR" || { echo "拿不到 inbox 锁,什么都没改,过几秒重试" >&2; exit 2; }
trap 'inbox_unlock "$STATE_DIR"' EXIT

old=$(cat "$INBOX" 2>/dev/null); [ -z "$old" ] && old='[]'
printf '%s' "$old" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || { echo "inbox.json 不是合法 JSON 数组,什么都没改" >&2; exit 1; }

ids_json=$(printf '%s\n' "${IDS[@]}" | jq -R . | jq -sc 'map(select(length > 0))')
KEY='(if .id != null then (.id|tostring) else ((.who // "" | tostring) + "|" + (.at // "" | tostring)) end)'

missing=$(jq -nr --argjson a "$old" --argjson ids "$ids_json" \
  "[\$a[] | $KEY] as \$have | \$ids - \$have | .[]")
[ -n "$missing" ] && printf 'inbox 里没有这些 id(可能已经 ack 过):%s\n' "$(echo $missing)" >&2

left=$(jq -c --argjson ids "$ids_json" "[ .[] | select(($KEY) as \$k | \$ids | index(\$k) | not) ]" <<< "$old") \
  || { echo "过滤失败,什么都没改" >&2; exit 1; }
inbox_lock_owned "$STATE_DIR" || { echo "inbox 锁途中被接管,什么都没改,重试一次" >&2; exit 2; }
inbox_write "$INBOX" "$left" || { echo "写 inbox 失败" >&2; exit 1; }

removed=$(( $(jq 'length' <<< "$old") - $(jq 'length' <<< "$left") ))
n=$(jq 'length' <<< "$left")
echo "watch '$NAME': 删掉 $removed 项,还剩 $n 项"
if [ "$n" -gt 0 ]; then
  jq -r ".[] | \"  - \\($KEY): \\((.body // .title // .kind // \"\") | tostring | .[0:80])\"" <<< "$left"
  exit 10
fi
exit 0
