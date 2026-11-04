// 加载 slkcli 的 slackApi 和 getCredentials,三个 slk-*.mjs 共用。
// 默认用本目录 npm install 装好的 slkcli 包;设了 SLKCLI_DIR 时改从那个本地 checkout 加载。
// slkcli 从本机 Slack 桌面 app 读登录态(token 和 d cookie),这里只拿函数,不打印、不落盘任何凭据。

import { join } from "node:path";
import { pathToFileURL } from "node:url";

const dir = process.env.SLKCLI_DIR;
const load = (file) => dir
  ? import(pathToFileURL(join(dir, "src", file)).href)
  : import(`slkcli/src/${file}`);

export const { slackApi } = await load("api.js");
export const { getCredentials } = await load("auth.js");
