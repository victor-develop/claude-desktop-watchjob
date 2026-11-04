#!/usr/bin/env node
// 以用户本人的账号发一条自动回复:署名放在 context block 里显示成小号灰字,正文转成 rich_text block(列表、代码块、引用是各自的节点)。
// 正文从 stdin 读(按 Markdown 写),不经过命令行参数。
// 用法: [AUTO_REPLY_BYLINE=<署名>] node slk-reply.mjs <channel> [thread_ts] < body.md
// 署名要和 slack-live.py 用的 AUTO_REPLY_BYLINE 一致:监听按署名认出自己发的自动回复,跳过以免循环。
// 成功时打印一行 JSON,带 ok、channel、ts、permalink 四个字段。token、cookie 不打印。

import { getCredentials } from "./slkcli.mjs";

const BYLINE = process.env.AUTO_REPLY_BYLINE || ":robot_face: Auto-reply from agent";

const [channel, threadTs] = process.argv.slice(2);
if (!/^[CDG][A-Z0-9]+$/.test(channel || "") || (threadTs && !/^\d+\.\d+$/.test(threadTs))) {
  console.error("usage: node slk-reply.mjs <channel> [thread_ts] < body.md");
  process.exit(2);
}

const chunks = [];
for await (const c of process.stdin) chunks.push(c);
const body = Buffer.concat(chunks).toString("utf8").trim();
if (!body) {
  console.error("正文为空");
  process.exit(2);
}

// 通知预览用的 text:行内代码里的内容不转换。
function toMrkdwn(md) {
  return md.split("\n").map((line) => line
    .replace(/^(\s*)[-*] /, "$1• ")
    .split(/(`[^`\n]+`)/)
    .map((part, i) => i % 2 ? part : part
      .replace(/\[([^\]\n]+)\]\((\S+?)\)/g, "<$2|$1>")
      .replace(/\*\*(?!\s)(.+?)(?<!\s)\*\*/g, "*$1*")
      .replace(/~~(?!\s)(.+?)(?<!\s)~~/g, "~$1~"))
    .join(""))
    .join("\n");
}

// 行内:`代码`、[文字](链接)、<链接|文字>、<@用户>、**粗体**、~~删除线~~、*斜体* 或 _斜体_,其余是普通文字。
const INLINE = /`([^`\n]+)`|\[([^\]\n]+)\]\((\S+?)\)|<(https?:[^|>\s]+)(?:\|([^>\n]+))?>|<@([UW][A-Z0-9]+)>|\*\*(?!\s)(.+?)(?<!\s)\*\*|~~(?!\s)(.+?)(?<!\s)~~|(?<![*\w])[*_](?![\s*_])([^*_\n]+?)(?<!\s)[*_](?![*\w])/g;

function inline(text, style) {
  const out = [];
  const push = (el) => out.push(style && el.type !== "user" ? { ...el, style: { ...style, ...el.style } } : el);
  let last = 0;
  for (const m of text.matchAll(INLINE)) {
    if (m.index > last) push({ type: "text", text: text.slice(last, m.index) });
    const [, code, mdText, mdUrl, angleUrl, angleText, userId, bold, strike, italic] = m;
    if (code) push({ type: "text", text: code, style: { code: true } });
    else if (mdUrl) push({ type: "link", url: mdUrl, text: mdText });
    else if (angleUrl) push({ type: "link", url: angleUrl, ...(angleText ? { text: angleText } : {}) });
    else if (userId) push({ type: "user", user_id: userId });
    else if (bold) out.push(...inline(bold, { ...style, bold: true }));
    else if (strike) out.push(...inline(strike, { ...style, strike: true }));
    else if (italic) out.push(...inline(italic, { ...style, italic: true }));
    last = m.index + m[0].length;
  }
  if (last < text.length) push({ type: "text", text: text.slice(last) });
  return out;
}

const LIST_ITEM = /^(\s*)([-*•]|\d+[.)])\s+(.*)$/;

// Markdown 转成一个 rich_text block:段落是 rich_text_section,列表是 rich_text_list(按缩进分层),
// ``` 代码块是 rich_text_preformatted,> 引用是 rich_text_quote,# 标题按粗体段落处理。
function richText(md) {
  const elements = [];
  const lines = md.split("\n");
  let para = [];
  const flushPara = () => {
    if (!para.length) return;
    const parts = [];
    para.forEach((line, i) => {
      if (i) parts.push({ type: "text", text: "\n" });
      const heading = line.match(/^#{1,6}\s+(.*)$/);
      parts.push(...(heading ? inline(heading[1], { bold: true }) : inline(line)));
    });
    elements.push({ type: "rich_text_section", elements: parts });
    para = [];
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/^```/.test(line)) {
      flushPara();
      const code = [];
      while (++i < lines.length && !/^```/.test(lines[i])) code.push(lines[i]);
      elements.push({ type: "rich_text_preformatted", elements: [{ type: "text", text: code.join("\n") || " " }] });
      continue;
    }
    if (/^>\s?/.test(line)) {
      flushPara();
      const quote = [];
      for (; i < lines.length && /^>\s?/.test(lines[i]); i++) quote.push(lines[i].replace(/^>\s?/, ""));
      i--;
      const parts = [];
      quote.forEach((q, j) => { if (j) parts.push({ type: "text", text: "\n" }); parts.push(...inline(q)); });
      elements.push({ type: "rich_text_quote", elements: parts });
      continue;
    }
    const item = line.match(LIST_ITEM);
    if (item) {
      flushPara();
      for (; i < lines.length; i++) {
        const m = lines[i].match(LIST_ITEM);
        if (!m) break;
        const indent = Math.min(Math.floor(m[1].replace(/\t/g, "  ").length / 2), 6);
        const style = /\d/.test(m[2]) ? "ordered" : "bullet";
        const prev = elements[elements.length - 1];
        const section = { type: "rich_text_section", elements: inline(m[3]) };
        if (prev?.type === "rich_text_list" && prev.style === style && prev.indent === indent) prev.elements.push(section);
        else elements.push({ type: "rich_text_list", style, indent, elements: [section] });
      }
      i--;
      continue;
    }
    if (!line.trim()) {
      flushPara();
      continue;
    }
    para.push(line);
  }
  flushPara();
  return { type: "rich_text", elements };
}

const mrkdwn = toMrkdwn(body);
const blocks = [
  { type: "context", elements: [{ type: "mrkdwn", text: BYLINE }] },
  richText(body),
];

const { token, cookie } = await getCredentials();
const post = async (method, params) => {
  const res = await fetch(`https://slack.com/api/${method}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, Cookie: `d=${cookie}`, "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify(params),
  });
  return res.json();
};

// text 是通知预览和不显示 block 的客户端的退路,带上完整的署名加正文。
const sent = await post("chat.postMessage", {
  channel, thread_ts: threadTs, text: `${BYLINE}\n${mrkdwn}`, blocks, unfurl_links: false,
});
if (!sent.ok) {
  console.error(`chat.postMessage failed: ${sent.error}`);
  process.exit(1);
}
const linkRes = await fetch(`https://slack.com/api/chat.getPermalink?channel=${encodeURIComponent(sent.channel)}&message_ts=${encodeURIComponent(sent.ts)}`, {
  headers: { Authorization: `Bearer ${token}`, Cookie: `d=${cookie}` },
});
const link = await linkRes.json();
process.stdout.write(JSON.stringify({ ok: true, channel: sent.channel, ts: sent.ts, permalink: link.permalink || "" }) + "\n");
