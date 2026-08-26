#!/bin/bash
# 通用 HTTP JSON 源。任何返回 JSON 列表、且每项带时间戳/递增序号的接口都能接。
#
# 配置(环境变量):
#   URL       必需  请求地址。可以用 {{cursor}} 占位符做服务端过滤,会被当前游标替换
#   MAP       必需  jq 表达式,把响应转成本机制要的数组形状。至少要产出 `at`
#   TIMEOUT   可选  超时秒数,默认 20
#   HEADER    可选  额外请求头,可重复,用 ; 分隔多条,如 'Accept: application/json'
#
# 认证:靠启动会话已有的环境(后台进程继承钥匙串和已登录的 CLI),或者由调用方在
# HEADER 里引用一个已经存在的环境变量。**不要把 token 字面量写进脚本或命令行** ——
# 命令行参数在进程表里是所有人可见的。
#
# 用法:
#   export URL='https://api.example.com/tickets?since={{cursor}}'
#   export MAP='[ .items[] | {id: .id, at: .updated_at, kind:"ticket",
#                             title: .title[0:120], status: .status} ]'
#   scripts/watch-loop.sh --name tickets --probe scripts/templates/probe-http-json.sh --seed
#   scripts/watch-loop.sh --name tickets --probe scripts/templates/probe-http-json.sh \
#     --interval 300 --backoff
#
# 想让它收尾,就在 MAP 里给对应的项加上 kind:"terminal"。例如只关心状态变成 done:
#   MAP='[ .items[] | select(.status=="done") | {id:.id, at:.updated_at, kind:"terminal"} ]'

set -uo pipefail
. "$(dirname "$0")/_lib.sh"
require_bin curl jq
require_env URL MAP

TIMEOUT="${TIMEOUT:-20}"
CURSOR="${PROBE_CURSOR:-}"

# {{cursor}} 替换。游标可能含特殊字符,做一次 URL 编码
enc=$(printf '%s' "$CURSOR" | jq -sRr @uri)
REQ_URL=${URL//\{\{cursor\}\}/$enc}

curl_args=(-sS --max-time "$TIMEOUT" --fail-with-body)
if [ -n "${HEADER:-}" ]; then
  IFS=';' read -ra hs <<< "$HEADER"
  for h in "${hs[@]}"; do
    h="${h#"${h%%[![:space:]]*}"}"          # 去掉前导空格
    [ -n "$h" ] && curl_args+=(-H "$h")
  done
fi

# -- 之后的东西一律当 URL,不然以 - 开头的 URL 会被 curl 解析成选项
RESP=$(curl "${curl_args[@]}" -- "$REQ_URL" 2>/dev/null); rc=$?
[ $rc -ne 0 ] && { echo "curl 失败(rc=$rc),URL=${REQ_URL%%\?*}" >&2; exit 3; }
[ -z "$RESP" ] && { echo "响应为空,URL=${REQ_URL%%\?*}" >&2; exit 3; }

printf '%s' "$RESP" | jq -c "$MAP | sort_by(.at)" 2>/dev/null \
  || { echo "MAP 表达式跑不通,或响应不是预期的 JSON 结构" >&2; exit 3; }
