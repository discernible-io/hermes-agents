#!/usr/bin/env node
/** Print own Passport owner_id (JWT aud). Usage: node probe-audience.mjs */
import { readdirSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";

process.env.LOG_LEVEL = process.env.LOG_LEVEL || "error";
process.env.SUPPRESS_NO_CONFIG_WARNING = "true";
process.env.SUPPRESS_STRICTNESS_CHECK = "true";

function credPath() {
  const explicit = process.env.NEAR_CREDENTIALS_FILE_PATH || "";
  if (explicit) return explicit;
  const dir =
    process.env.IDENTYCLAW_NEAR_CREDENTIALS_DIR ||
    join(process.env.IDENTYCLAW_HOME || "", "secrets/near-credentials");
  const files = readdirSync(dir).filter((n) => n.endsWith(".json"));
  if (!files.length) throw new Error("no NEAR credentials");
  return join(dir, files[0]);
}

// Rodit reads RODIT_NEAR_CREDENTIALS_SOURCE / NEAR_CREDENTIALS_FILE_PATH at
// module load — set them before require.
const path = credPath();
process.env.RODIT_NEAR_CREDENTIALS_SOURCE = "file";
process.env.NEAR_CREDENTIALS_FILE_PATH = path;
process.env.CREDENTIALS_FILE_PATH = path;
process.env.NEAR_CONTRACT_ID =
  process.env.NEAR_CONTRACT_ID ||
  process.env.IDENTYCLAW_NEAR_CONTRACT_ID ||
  "genaaaa-identyclaw-com.near";

const require = createRequire(import.meta.url);
const { RoditClient } = require("@rodit/rodit-auth-be");

let client;
try {
  client = await RoditClient.create({ role: "client" });
} catch {
  client = await RoditClient.create("client");
}
const own = await client.getConfigOwnRodit();
const ownerId = String(own?.own_rodit?.owner_id || "").trim();
if (!ownerId || !/^[0-9a-fA-F]{64}$/.test(ownerId)) {
  process.stderr.write(`own_rodit.owner_id missing or invalid: ${ownerId || "(empty)"}\n`);
  process.exit(1);
}
process.stdout.write(ownerId);
