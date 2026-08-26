#!/bin/bash
# 一个 PR + 它关联的 Slack thread,合成**一个** watch。
#
# 为什么合并:PR 上有人 review、thread 里有人追问,对你来说是同一次判断、同一条回复。
# 拆成两个 watch 就是同一件事把你叫醒两次,而唤醒是这套机制里唯一贵的东西。
# 反过来,三个互不相关的 PR 应该开三个 watch —— 它们是三次独立决策。
#
# 直接复用另外两个模板,不复制代码(复制出来的两份迟早会不一致)。
#
# 配置(环境变量):PR 侧和 Slack 侧的都要给
#   REPO, PR, GITHUB_SELF             见 probe-github-pr.sh
#   CHANNEL, THREAD_TS, SLACK_SELF    见 probe-slack-thread.sh
#
# 这里必须用 GITHUB_SELF / SLACK_SELF 两个名字。两个模板单独用时都认 SELF,合在一起时
# 后设的那个会盖掉前一个 —— 被盖掉的那一侧就不再过滤自己,于是你自己的回复把自己叫醒,
# 正好是这套机制最容易翻的车。
#
# 用法:
#   export REPO=owner/repo PR=123 GITHUB_SELF=your-login
#   export CHANNEL=C0XXXXXXXXX THREAD_TS=1700000000.000000 SLACK_SELF=U0XXXXXXXXX
#   scripts/watch-loop.sh --name pr-123 --probe scripts/templates/probe-pr-and-slack.sh --seed
#   scripts/watch-loop.sh --name pr-123 --probe scripts/templates/probe-pr-and-slack.sh --interval 120
#
# 游标怎么办:两个源的 at 不同量纲(ISO8601 vs Slack ts),直接混排会错。这里把两边都
# 归一成 ISO8601 再排序,原始值留在 raw_at 里,你回复 Slack 时需要它。

set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_lib.sh"
require_bin gh slackcli jq
require_env REPO PR GITHUB_SELF CHANNEL THREAD_TS SLACK_SELF
unset SELF   # 防止一个含糊的 SELF 悄悄顶替掉某一侧

GH=$("$DIR/probe-github-pr.sh"); gh_rc=$?
[ $gh_rc -ne 0 ] && { echo "GitHub 侧失败(rc=$gh_rc)" >&2; exit $gh_rc; }

SK=$("$DIR/probe-slack-thread.sh"); sk_rc=$?
[ $sk_rc -ne 0 ] && { echo "Slack 侧失败(rc=$sk_rc)" >&2; exit $sk_rc; }

# Slack ts(秒.微秒)→ ISO8601,好跟 GitHub 的时间戳排在一起。
# todate 会截到整秒,而这个值就是游标 —— 同一秒内的第二条回复会因为 .at > cursor 不成立
# 而被永久跳过。所以把小数部分接回去。
jq -n --argjson gh "$GH" --argjson sk "$SK" '
  ($sk | map(. + {
      raw_at: .at,
      at: ((.at | tonumber | floor | todate | rtrimstr("Z"))
           + "." + ((.at | split(".") | .[1] // "000000")) + "Z")
    }))
  + ($gh | map(. + {raw_at: .at}))
  | sort_by(.at)'
