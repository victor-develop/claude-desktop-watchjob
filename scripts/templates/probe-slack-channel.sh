#!/bin/bash
# 兼容入口:盯一个 Slack 频道 / DM,等于 probe-slack.sh 的 all-threads 模式
# (EXCLUDE_REPLIES=1 时是 top-level 模式)。
#
# 实现和全部配置说明都在 probe-slack.sh(三种模式共用一份代码)。这个文件留着,是为了让
# 已经在跑的 watch 不用改配置、不用重新 seed:游标和输出形状都不变。
#
# 行为变化(修 bug):这个模板以前的注释说「默认包含 thread 回复」,但它读的是
# conversations.history,拿不到 thread 回复,有人回在 thread 里 watch 就一直不响。
# 现在默认真的会看 thread 回复(最近 THREAD_SCAN=30 条顶层消息底下的),每轮多 1 次请求,
# 加上有新回复的 thread 各 1 次。只要顶层就 EXCLUDE_REPLIES=1 或 SLACK_MODE=top-level。
#
# 必需环境变量:CHANNEL SELF(或 SLACK_SELF)。新 watch 直接用 probe-slack.sh。
#
# 外面显式给了 SLACK_MODE 就照它来;没给时不看 THREAD_TS(这个文件以前也不看),
# 免得环境里留着的 THREAD_TS 把它悄悄变成 thread 模式。
if [ -z "${SLACK_MODE:-}" ]; then
  case "${EXCLUDE_REPLIES:-0}" in
    1|true|yes) SLACK_MODE=top-level ;;
    *) SLACK_MODE=all-threads ;;
  esac
fi
export SLACK_MODE
exec "$(dirname "$0")/probe-slack.sh"
