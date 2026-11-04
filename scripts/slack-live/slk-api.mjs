#!/usr/bin/env node
// 用 slkcli 发一次 Slack 只读调用,把响应 JSON 打到 stdout。
// token 和 cookie 留在 slkcli 内部,这个脚本和它的调用方都拿不到。
// 用法: node slk-api.mjs <method> '<params-json>'

import { slackApi } from "./slkcli.mjs";

const method = process.argv[2];
const params = process.argv[3] ? JSON.parse(process.argv[3]) : {};

if (!/^[a-z]+(\.[A-Za-z]+)+$/.test(method || "")) {
  console.error("usage: node slk-api.mjs <method> '<params-json>'");
  process.exit(2);
}

try {
  const data = await slackApi(method, params);
  process.stdout.write(JSON.stringify(data));
} catch (err) {
  console.error(String(err && err.message ? err.message : err));
  process.exit(1);
}
