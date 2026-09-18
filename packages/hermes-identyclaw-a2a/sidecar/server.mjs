#!/usr/bin/env node
/**
 * Passport JWT auth sidecar for Hermes identyclaw-a2a.
 *
 * Loopback only (127.0.0.1:9910 by default):
 *   GET  /health
 *   GET  /api/login/timestamp
 *   POST /api/login              → RoditClient.login_client (peers log into this host)
 *   POST /validate_jwt           → validate_jwt_token_be (inbound A2A)
 *   POST /login_server           → login_server against a peer base URL (outbound A2A)
 *
 * Never logs JWT values.
 */
import { createRequire } from "node:module";
import { readdirSync } from "node:fs";
import { join } from "node:path";
import express from "express";

process.env.LOG_LEVEL = process.env.LOG_LEVEL || "error";
process.env.SUPPRESS_NO_CONFIG_WARNING = process.env.SUPPRESS_NO_CONFIG_WARNING || "true";
process.env.SUPPRESS_STRICTNESS_CHECK = process.env.SUPPRESS_STRICTNESS_CHECK || "true";
process.env.SECURITY_OPTIONS_LOGIN_MODE =
  process.env.SECURITY_OPTIONS_LOGIN_MODE || "promiscuous";

const require = createRequire(import.meta.url);
const rodit = require("@rodit/rodit-auth-be");
const {
  RoditClient,
  validate_jwt_token_be,
  login_server,
} = rodit;

const HOST = process.env.A2A_AUTH_SIDECAR_HOST || "127.0.0.1";
const PORT = Number(process.env.A2A_AUTH_SIDECAR_PORT || 9910);
const ISSUER = (process.env.IDENTYCLAW_JWT_ISSUER || "https://api.identyclaw.com").replace(/\/$/, "");

function firstNearCredsPath() {
  const explicit =
    process.env.NEAR_CREDENTIALS_FILE_PATH ||
    process.env.CREDENTIALS_FILE_PATH ||
    "";
  if (explicit) return explicit;
  const dir =
    process.env.IDENTYCLAW_NEAR_CREDENTIALS_DIR ||
    "/opt/data/secrets/near-credentials";
  const files = readdirSync(dir).filter((n) => n.endsWith(".json"));
  if (!files.length) {
    throw new Error(`No NEAR credentials JSON in ${dir}`);
  }
  return join(dir, files[0]);
}

function applyNearEnv() {
  const credPath = firstNearCredsPath();
  process.env.RODIT_NEAR_CREDENTIALS_SOURCE = "file";
  process.env.NEAR_CREDENTIALS_FILE_PATH = credPath;
  process.env.CREDENTIALS_FILE_PATH = credPath;
  process.env.NEAR_CONTRACT_ID =
    process.env.NEAR_CONTRACT_ID ||
    process.env.IDENTYCLAW_NEAR_CONTRACT_ID ||
    "genaaaa-identyclaw-com.near";
  return credPath;
}

async function createClient(role) {
  try {
    return await RoditClient.create({ role });
  } catch {
    return await RoditClient.create(role);
  }
}

function audienceRodit(audience, issuer) {
  return {
    token_id: "a2a-inbound",
    owner_id: audience,
    metadata: { subjectuniqueidentifier_url: issuer || ISSUER },
  };
}

function identityFromResult(result) {
  const payload = result?.payload || {};
  const peer = result?.peer_rodit || {};
  const candidates = [
    payload.token_id,
    peer.token_id,
    payload.rodit_id,
    payload.sub,
  ];
  for (const c of candidates) {
    const label = String(c || "").trim();
    if (label) return label;
  }
  return "";
}

function timestampPayload() {
  const now = new Date();
  return {
    timestamp: Math.floor(now.getTime() / 1000),
    timestamp_iso: now.toISOString(),
  };
}

async function main() {
  const credPath = applyNearEnv();
  const client = await createClient("client");
  const serverClient = await createClient("server");
  const own = await client.getConfigOwnRodit();
  const audience =
    (process.env.IDENTYCLAW_JWT_AUDIENCE || "").trim() ||
    String(own?.own_rodit?.owner_id || "").trim();
  if (!audience) {
    throw new Error("IDENTYCLAW_JWT_AUDIENCE / own_rodit.owner_id missing");
  }

  const app = express();
  app.disable("x-powered-by");
  app.use(express.json({ limit: "256kb" }));

  app.get("/health", (_req, res) => {
    res.json({ ok: true, auth: "passport-jwt", audience_set: true });
  });

  app.get("/api/login/timestamp", (_req, res) => {
    res.json(timestampPayload());
  });

  app.post("/api/login", (req, res) => {
    req.logAction = "login-attempt";
    serverClient.login_client(req, res);
  });

  app.post("/validate_jwt", async (req, res) => {
    const token = String(req.body?.token || "").trim();
    const aud = String(req.body?.audience || audience).trim();
    const issuer = String(req.body?.issuer || ISSUER).trim();
    if (!token) {
      res.status(400).json({ ok: false, error: "missing token" });
      return;
    }
    try {
      const result = await validate_jwt_token_be(token, audienceRodit(aud, issuer), {
        enforceSessionRegistration: false,
      });
      const tokenId = identityFromResult(result);
      if (!result?.valid || !tokenId) {
        res.status(401).json({ ok: false, error: "invalid token" });
        return;
      }
      res.json({ ok: true, token_id: tokenId });
    } catch (err) {
      res.status(401).json({ ok: false, error: "invalid token" });
    }
  });

  app.post("/login_server", async (req, res) => {
    const apiEndpoint = String(req.body?.apiEndpoint || "").trim().replace(/\/$/, "");
    if (!apiEndpoint) {
      res.status(400).json({ ok: false, error: "missing apiEndpoint" });
      return;
    }
    try {
      const targeted = {
        ...own,
        own_rodit: {
          ...own.own_rodit,
          metadata: {
            ...(own.own_rodit?.metadata || {}),
            subjectuniqueidentifier_url: apiEndpoint,
          },
        },
      };
      const result = await login_server(targeted, {
        loginPath: "/api/login",
        timestampPath: "/api/login/timestamp",
      });
      if (!result?.jwt_token || result.error) {
        res.status(401).json({ ok: false, error: result?.error || "login_server failed" });
        return;
      }
      res.json({ ok: true, jwt: result.jwt_token, ttl_seconds: 300 });
    } catch (err) {
      res.status(502).json({ ok: false, error: "login_server failed" });
    }
  });

  app.listen(PORT, HOST, () => {
    process.stdout.write(
      `identyclaw-a2a sidecar listening on ${HOST}:${PORT} (creds ${credPath})\n`,
    );
  });
}

main().catch((err) => {
  process.stderr.write(`identyclaw-a2a sidecar failed: ${err?.message || err}\n`);
  process.exit(1);
});
