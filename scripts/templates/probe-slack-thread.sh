#!/bin/bash
# 兼容入口:等于 `SLACK_MODE=thread probe-slack.sh` —— 盯一条 Slack thread 的回复。
#
# 实现和全部配置说明都在 probe-slack.sh(三种模式共用一份代码)。这个文件留着,是为了让
# 已经在跑的 watch、以及 probe-pr-and-slack.sh 不用改:环境变量、游标、输出形状都不变
# (输出多了一个 thread_ts 字段;父消息本身 kind 变成 slack-message,回复仍是 slack-reply)。
#
# 必需环境变量:CHANNEL THREAD_TS SELF(或 SLACK_SELF)。新 watch 直接用 probe-slack.sh。
#
# 这里强制 thread 模式,不看外面的 SLACK_MODE:这个文件以前不认 SLACK_MODE,
# 环境里碰巧留着别的值也不该改变它的行为。
export SLACK_MODE=thread
exec "$(dirname "$0")/probe-slack.sh"
