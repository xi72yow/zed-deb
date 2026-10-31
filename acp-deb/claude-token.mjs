// long-lived claude token of the sandbox in the os keyring, read or written over d-bus
// usage: node claude-token.mjs get | set (token on stdin) | clear

import { entry } from "./keyring.mjs";

const token = entry("zed-acp-sandbox", "claude-oauth-token");

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8").trim();
}

switch (process.argv[2]) {
  case "get": {
    const value = await token.get();
    if (!value) process.exit(1);
    process.stdout.write(value);
    break;
  }
  case "set": {
    const value = await readStdin();
    if (!value) {
      console.error("empty token, nothing stored");
      process.exit(1);
    }
    await token.set(value);
    break;
  }
  case "clear":
    await token.clear();
    break;
  default:
    console.error("usage: claude-token.mjs get | set | clear");
    process.exit(2);
}
