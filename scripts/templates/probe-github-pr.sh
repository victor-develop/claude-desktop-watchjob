#!/bin/bash
# 盯一个 GitHub PR:普通评论 + inline review 评论 + review 状态。
# PR 被 merge 或 close 时报 terminal,循环收尾。
#
# 用 GitHub CLI(gh)。三个 endpoint 都要拉,少一个就会漏:
#   repos/{r}/issues/{n}/comments  —— PR 对话区的普通评论
#   repos/{r}/pulls/{n}/comments   —— 挂在代码行上的 inline review 评论
#   repos/{r}/pulls/{n}/reviews    —— review 本身(APPROVED / CHANGES_REQUESTED 及其正文)
# 全部带 --paginate。评论过百的 PR 只拉第一页会静默漏掉后面的。
#
# 配置(环境变量):
#   REPO      必需  owner/repo
#   PR        必需  PR 号
#   SELF      必需  你自己的 GitHub login。不填会被自己的回复叫醒,死循环
#             也可以用 GITHUB_SELF —— 跟 Slack 模板同时用时,两边的 SELF 会互相覆盖,
#             那种场合请显式用 GITHUB_SELF / SLACK_SELF
#   BOT_RE    可选  额外要过滤的账号正则,默认 '\[bot\]$|^web-flow$'
#   TIMEOUT   可选  单次 gh 调用超时秒数,默认 60。分页多的 PR 别调太小
#   BODY_MAX  可选  正文截断长度,默认 280
#
# 用法:
#   export REPO=owner/repo PR=123 SELF=your-login
#   scripts/watch-loop.sh --name pr-123 --probe scripts/templates/probe-github-pr.sh --seed
#   scripts/watch-loop.sh --name pr-123 --probe scripts/templates/probe-github-pr.sh \
#     --interval 120 --max-runtime 5400
#
# 环境变量由启动 watch-loop 的那个 shell 继承下来,所以要在同一条命令里 export。

set -uo pipefail
. "$(dirname "$0")/_lib.sh"
require_bin gh jq
SELF="${GITHUB_SELF:-${SELF:-}}"
require_env REPO PR SELF

BOT_RE="${BOT_RE:-$default_bot_re}"
TIMEOUT="${TIMEOUT:-60}"
BODY_MAX="${BODY_MAX:-280}"
# BODY_MAX 是拼进 jq 程序文本的,不是 --arg。拼错一个数字会变成难懂的 jq 语法错误,
# 先挡住(Slack 侧用的是 --argjson,天然没这问题)
case "$BODY_MAX" in ''|*[!0-9]*) echo "BODY_MAX 必须是非负整数,收到: '$BODY_MAX'" >&2; exit 2 ;; esac

# 先判终止 —— PR 已经关掉就没必要再翻评论
STATE=$(fetch_with_retry "$TIMEOUT" gh pr view "$PR" --repo "$REPO" --json state --jq .state 2>/dev/null)
[ -z "$STATE" ] && { echo "gh pr view 拿不到状态(超时/无权限/PR 不存在): $REPO#$PR" >&2; exit 3; }

if [ "$STATE" = "MERGED" ] || [ "$STATE" = "CLOSED" ]; then
  jq -n --arg s "$STATE" --arg t "$(date -u '+%FT%TZ')" --arg r "$REPO" --arg p "$PR" \
    '[{kind:"terminal", at:$t, source:"github-pr", repo:$r, pr:$p, state:$s}]'
  exit 0
fi

# 任何一个 endpoint 失败都必须让整个 probe 失败。
# 拿到半截数据却当成功返回,游标照样往前推 —— 被截掉的那条 review 就永久错过了,
# 而且没有任何迹象。宁可 exit 3 把 agent 叫起来看错误。
fetch() {  # $1=人话描述  其余=gh 参数
  local label="$1"; shift
  local out rc
  local err
  err=$(mktemp)
  out=$(fetch_with_retry "$TIMEOUT" gh "$@" 2>"$err"); rc=$?
  if [ $rc -ne 0 ]; then
    echo "拉取失败(rc=$rc): $label。可能是超时(当前 TIMEOUT=${TIMEOUT}s)、限流或权限。" >&2
    # gh 的原话才是能拿来修的东西(限流 vs 404 vs token 过期)。循环会把它追加进 log
    sed 's/^/  gh: /' "$err" >&2; rm -f "$err"
    echo "整个 probe 判为失败 —— 只用一部分数据会静默丢事件。" >&2
    return 1
  fi
  rm -f "$err"
  printf '%s\n' "$out"
}

C_ISSUE=$(fetch "PR 普通评论" api --paginate "repos/$REPO/issues/$PR/comments" \
  --jq ".[] | {id:(\"ic\"+(.id|tostring)), who:(.user.login // \"ghost\"), at:.updated_at,
               kind:\"pr-comment\", body:.body[0:$BODY_MAX]}") || exit 3

C_INLINE=$(fetch "inline review 评论" api --paginate "repos/$REPO/pulls/$PR/comments" \
  --jq ".[] | {id:(\"rc\"+(.id|tostring)), who:(.user.login // \"ghost\"), at:.updated_at,
               kind:\"pr-inline\", path:.path, body:.body[0:$BODY_MAX]}") || exit 3

C_REVIEW=$(fetch "review 状态" api --paginate "repos/$REPO/pulls/$PR/reviews" \
  --jq ".[] | select(.submitted_at != null) |
        {id:(\"rv\"+(.id|tostring)), who:(.user.login // \"ghost\"), at:.submitted_at,
         kind:\"pr-review\", state:.state, body:((.body // \"\")[0:$BODY_MAX])}") || exit 3

printf '%s\n%s\n%s\n' "$C_ISSUE" "$C_INLINE" "$C_REVIEW" \
  | jq -sc --arg self "$SELF" --arg bots "$BOT_RE" \
      '[ .[]
         | select(.who != $self)
         | select(.who | test($bots) | not)
       ] | sort_by(.at)'
