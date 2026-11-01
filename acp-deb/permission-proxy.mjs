#!/usr/bin/env node
// stdio proxy between zed and the acp agent: every permission request also opens a window, the
// first answer from either side wins
// usage: permission-proxy.mjs <agent command> [args...]

import { spawn } from "node:child_process";
import { basename, join } from "node:path";
import { createInterface } from "node:readline";

const [command, ...args] = process.argv.slice(2);
const POPUP = process.env.ZED_ACP_POPUP_COMMAND?.split(" ") ?? ["gjs", "-m", join(import.meta.dirname, "permission-popup.js")];

const agent = spawn(command, args, { stdio: ["pipe", "pipe", "inherit"] });

const requests = new Map();
const key = (id) => JSON.stringify(id);
const toZed = (line) => process.stdout.write(`${line}\n`);
const toAgent = (line) => agent.stdin.write(`${line}\n`);
const rpc = (message) => JSON.stringify({ jsonrpc: "2.0", ...message });

function renderContent(item) {
  if (item.type === "diff") {
    return [`Datei: ${item.path}`, "", "--- alt", item.oldText ?? "", "", "+++ neu", item.newText ?? ""].join("\n");
  }
  return item.content?.text ?? "";
}

function describe({ toolCall }) {
  const input = toolCall?.rawInput ?? {};
  const rendered = (toolCall?.content ?? []).map(renderContent).filter(Boolean);
  if (rendered.length) return rendered.join("\n\n");
  return input.command ?? JSON.stringify(input, null, 2);
}

function openPopup(entry, params) {
  const popup = spawn(POPUP[0], POPUP.slice(1), {
    env: { ...process.env, GDK_BACKEND: "x11" },
    stdio: ["pipe", "pipe", "inherit"],
  });
  let chosen = "";
  popup.stdout.on("data", (chunk) => (chosen += chunk));
  // without gjs the request simply stays with zed
  popup.on("error", (error) => console.error(`permission popup failed: ${error.message}`));
  popup.stdin.on("error", () => {});
  popup.on("exit", () => {
    const optionId = chosen.trim();
    if (optionId) onChoice(entry, optionId);
  });
  popup.stdin.end(
    JSON.stringify({
      project: basename(process.cwd()),
      title: params.toolCall?.title ?? "Berechtigung",
      detail: describe(params),
      options: params.options,
    }),
  );
  return popup;
}

function settle(entry) {
  entry.settled = true;
  entry.popup.kill();
}

function onChoice(entry, optionId) {
  if (entry.settled) return;
  settle(entry);
  toAgent(rpc({ id: entry.id, result: { outcome: { outcome: "selected", optionId } } }));
  toZed(rpc({ method: "$/cancel_request", params: { requestId: entry.id } }));
}

function parse(line) {
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
}

createInterface({ input: agent.stdout }).on("line", (line) => {
  const message = parse(line);
  if (message?.method === "$/cancel_request") {
    const entry = requests.get(key(message.params?.requestId));
    if (entry) settle(entry);
  }
  toZed(line);
  if (message?.method === "session/request_permission" && message.id !== undefined) {
    const entry = { id: message.id, settled: false };
    requests.set(key(message.id), entry);
    entry.popup = openPopup(entry, message.params);
  }
});

createInterface({ input: process.stdin })
  .on("line", (line) => {
    const message = parse(line);
    const entry = message && !message.method ? requests.get(key(message.id)) : undefined;
    if (entry?.settled) return;
    if (entry) settle(entry);
    toAgent(line);
  })
  .on("close", () => agent.stdin.end());

function shutdown(code) {
  for (const entry of requests.values()) entry.popup.kill();
  process.exit(code);
}

agent.on("exit", (code) => shutdown(code ?? 1));
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    agent.kill(signal);
    shutdown(1);
  });
}
