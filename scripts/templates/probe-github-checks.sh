#!/bin/bash
# 等一个 PR 的 CI 跑完。跑完就报 terminal —— 全绿要叫你,红了更要叫你。
# 中间态返回空数组,循环继续睡,不花任何 token。
#
# 配置(环境变量):
#   REPO      必需  owner/repo
#   PR        必需  PR 号
#   TIMEOUT   可选  超时秒数,默认 25
#
# 用法(CI 变化快,间隔调小):
#   export REPO=owner/repo PR=123
#   scripts/watch-loop.sh --name ci-123 --probe scripts/templates/probe-github-checks.sh \
#     --interval 30 --max-runtime 3600
#
# 不需要 --seed:它不做增量比对,只判终态。

set -uo pipefail
. "$(dirname "$0")/_lib.sh"
require_bin gh jq
require_env REPO PR

TIMEOUT="${TIMEOUT:-25}"

# 先确认 PR 本身拿得到 —— repo 写错、token 过期、限流都在这一步大声失败。
# 不先做这步的话,下面「拿不到 checks 就当还没开始」会把认证问题伪装成安静等待。
STATE=$(fetch_with_retry "$TIMEOUT" gh pr view "$PR" --repo "$REPO" --json state --jq .state 2>&1)
if [ -z "$STATE" ] || [ "${STATE#*rror}" != "$STATE" ] || [ "${STATE#*not found}" != "$STATE" ]; then
  echo "gh pr view 失败: $REPO#$PR —— $STATE" >&2
  exit 3
fi

RAW=$(fetch_with_retry "$TIMEOUT" gh pr checks "$PR" --repo "$REPO" --json name,state,link,bucket 2>/dev/null)
rc=$?

# 到这一步 PR 是拿得到的,所以非 0 / 空基本只剩「一个 check 都还没建起来」这一种解释,
# 当作还没开始、继续等。
if [ $rc -ne 0 ] || [ -z "$RAW" ]; then
  echo "[]" ; exit 0
fi

# 用 gh 自己的 bucket 字段(pass / fail / pending / skipping / cancel),别自己维护 state 枚举。
# 手写枚举漏掉 TIMED_OUT、CANCELLED、ACTION_REQUIRED、WAITING 这些,会把它们误判成全绿。
printf '%s' "$RAW" | jq -c --arg t "$(date -u '+%FT%TZ')" --arg r "$REPO" --arg p "$PR" '
  def bucket_of: (.bucket // (
    if   (.state|IN("IN_PROGRESS","QUEUED","PENDING","WAITING","REQUESTED")) then "pending"
    elif (.state|IN("SUCCESS","NEUTRAL"))                                       then "pass"
    elif (.state|IN("SKIPPED"))                                                  then "skipping"
    elif (.state|IN("CANCELLED","TIMED_OUT","STALE"))                          then "cancel"
    else "fail" end));
  map(. + {b: bucket_of}) as $c |
  (($c | map(select(.b == "pending")) | length) > 0) as $running |
  ($c | map(select(.b == "fail" or .b == "cancel"))) as $bad |
  if $running then []
  elif ($bad | length) > 0 then
    [{kind:"terminal", at:$t, source:"github-checks", repo:$r, pr:$p, verdict:"failed",
      failed: ($bad | map({name, link, state}))}]
  else
    [{kind:"terminal", at:$t, source:"github-checks", repo:$r, pr:$p, verdict:"all-green",
      checks: ($c | length)}]
  end'
