#!/usr/bin/env node
/** Print own Passport owner_id (JWT aud). Usage: node probe-audience.mjs */
import { createRequire } from "node:module";
import { readdirSync } from "node:fs";
import { join } from "node:path";

process.env.LOG_LEVEL = process.env.LOG_LEVEL || "error";
process.env.SUPPRESS_NO_CONFIG_WARNING = "true";
process.env.SUPPRESS_STRICTNESS_CHECK = "true";

const require = createRequire(import.meta.url);
const { RoditClient } = require("@rodit/rodit-auth-be");

function credPath() {
  const explicit = process.env.NEAR_CREDENTIALS_FILE_PATH || "";
  if (explicit) return explicit;
  const dir = process.env.IDENTYCLAW_NEAR_CREDENTIALS_DIR || join(process.env.IDENTYCLAW_HOME || "", "secrets/near-credentials");
  const files = readdirSync(dir).filter((n) => n.endsWith(".json"));
  if (!files.length) throw new Error("no NEAR credentials");
  return join(dir, files[0]);
}

const path = credPath();
process.env.RODIT_NEAR_CREDENTIALS_SOURCE = "file";
process.env.NEAR_CREDENTIALS_FILE_PATH = path;
process.env.NEAR_CONTRACT_ID =
  process.env.NEAR_CONTRACT_ID ||
  process.env.IDENTYCLAW_NEAR_CONTRACT_ID ||
  "genaaaa-identyclaw-com.near";

let client;
try {
  client = await RoditClient.create({ role: "client" });
} catch {
  client = await RoditClient.create("client");
}
const own = await client.getConfigOwnRodit();
const ownerId = String(own?.own_rodit?.owner_id || "").trim();
if (!ownerId) {
  process.stderr.write("own_rodit.owner_id missing\n");
  process.exit(1);
}
process.stdout.write(ownerId);
