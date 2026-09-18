/**
 * Localhost-only HTTP sidecar for Hermes Python platforms.
 *
 * Routes:
 *   GET  /health
 *   GET  /v1/sessions
 *   GET  /v1/own_passport     → { ok, owner_id, token_id, issuer, webhook_url }
 *   POST /v1/validate_jwt     { token } → { valid, identity/token_id, … }
 *                               (aud/iss from RoditClient.getConfigOwnRodit)
 *   POST /v1/login_server     { apiEndpoint? } → { ok, jwt_token, jwt_length, token_id }
 *   POST /v1/authenticate_webhook
 *        { payload, signature, timestamp, publicKey } → { isValid, … }
 *   GET  /api/login/timestamp
 *   POST /api/login          (peer inbound login via RoditClient.login_client)
 */
import http from "node:http";
import {
  getServerClient,
  getClientClient,
  getAuthServices,
  validateInboundJwt,
  resolveOwnPassport,
  loginServerToPeer,
  wrapExpressLikeResponse,
  extractWebhookSignerKey,
  extractWebhookSessionId,
  applyLoginMode,
} from "./lib/rodit.mjs";
import { listSessions, ensureSession } from "./lib/session.mjs";
import { ensureRoditCredentialEnv, defaultBaseUrl } from "./lib/paths.mjs";

const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_PORT = Number(process.env.IDENTYCLAW_AUTH_PORT || 9910);

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Content-Length", Buffer.byteLength(body));
  res.end(body);
}

async function readJsonBody(req, maxBytes = 1024 * 1024) {
  const chunks = [];
  let total = 0;
  for await (const chunk of req) {
    const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    total += buf.length;
    if (total > maxBytes) {
      const err = new Error("payload too large");
      err.code = "PAYLOAD_TOO_LARGE";
      throw err;
    }
    chunks.push(buf);
  }
  if (!chunks.length) return {};
  const text = Buffer.concat(chunks).toString("utf8");
  if (!text.trim()) return {};
  const parsed = JSON.parse(text);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Invalid JSON body");
  }
  return parsed;
}

async function readRawBody(req, maxBytes = 1024 * 1024) {
  const chunks = [];
  let total = 0;
  for await (const chunk of req) {
    const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    total += buf.length;
    if (total > maxBytes) {
      const err = new Error("payload too large");
      err.code = "PAYLOAD_TOO_LARGE";
      throw err;
    }
    chunks.push(buf);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function pathname(url) {
  try {
    return new URL(url, "http://127.0.0.1").pathname;
  } catch {
    return url.split("?")[0] || "/";
  }
}

export function createAuthServer({ host = DEFAULT_HOST, port = DEFAULT_PORT } = {}) {
  ensureRoditCredentialEnv();
  applyLoginMode(process.env.SECURITY_OPTIONS_LOGIN_MODE || "promiscuous");

  const server = http.createServer(async (req, res) => {
    const path = pathname(req.url || "/");
    const method = (req.method || "GET").toUpperCase();

    try {
      if (method === "GET" && path === "/health") {
        return sendJson(res, 200, { ok: true, service: "hermes-identyclaw-auth" });
      }

      if (method === "GET" && path === "/v1/sessions") {
        return sendJson(res, 200, listSessions());
      }

      if (method === "GET" && path === "/v1/own_passport") {
        try {
          const passport = await resolveOwnPassport();
          return sendJson(res, 200, passport);
        } catch (err) {
          return sendJson(res, 503, {
            ok: false,
            error: err?.message || String(err),
          });
        }
      }

      if (method === "POST" && path === "/v1/ensure_session") {
        const body = await readJsonBody(req);
        const result = await ensureSession({
          baseUrl: body.baseUrl || defaultBaseUrl(),
          force: !!body.force,
          credentialsPath: body.credentialsPath || null,
        });
        return sendJson(res, 200, result);
      }

      if (method === "POST" && path === "/v1/validate_jwt") {
        const body = await readJsonBody(req);
        const result = await validateInboundJwt(body.token || "", {
          audience: body.audience,
          issuer: body.issuer,
        });
        return sendJson(res, result.valid ? 200 : 401, result);
      }

      if (method === "POST" && path === "/v1/login_server") {
        const body = await readJsonBody(req);
        const result = await loginServerToPeer({
          apiEndpoint: body.apiEndpoint || body.peerUrl || null,
          credentialsPath: body.credentialsPath || null,
        });
        return sendJson(res, 200, result);
      }

      if (method === "POST" && path === "/v1/authenticate_webhook") {
        const body = await readJsonBody(req);
        const auth = await getAuthServices();
        const client = await getClientClient();
        let publicKey = (body.publicKey || "").trim();
        if (!publicKey && body.headers) {
          const resolution = extractWebhookSignerKey(body.headers, client.getStateManager());
          publicKey = resolution?.key?.trim() || "";
        }
        if (!publicKey) {
          return sendJson(res, 401, {
            isValid: false,
            error: { code: "MISSING_SIGNER_KEY", message: "Webhook signer public key missing" },
          });
        }
        const authResult = await auth.authenticate_webhook(
          body.payload || "",
          body.signature || "",
          body.timestamp || "",
          publicKey
        );
        let sessionId = null;
        let sessionKnown = false;
        if (authResult.isValid) {
          sessionId = extractWebhookSessionId({
            headers: body.headers || {},
            rawPayload: body.payload || "",
          });
          if (sessionId) {
            try {
              sessionKnown = await client.getSessionManager().hasSession(sessionId);
            } catch {
              sessionKnown = false;
            }
          }
        }
        return sendJson(res, authResult.isValid ? 200 : 401, {
          ...authResult,
          sessionId,
          sessionKnown,
        });
      }

      if (method === "GET" && path === "/api/login/timestamp") {
        const timestamp = Math.floor(Date.now() / 1000);
        return sendJson(res, 200, {
          timestamp,
          timestamp_iso: new Date(timestamp * 1000).toISOString(),
        });
      }

      if (method === "POST" && path === "/api/login") {
        const body = await readJsonBody(req);
        const client = await getServerClient();
        const expressReq = Object.assign(req, {
          body,
          ip: req.socket?.remoteAddress || "",
        });
        await client.login_client(expressReq, wrapExpressLikeResponse(res, sendJson));
        return;
      }

      if (method === "POST" && path === "/v1/send_webhook") {
        const body = await readJsonBody(req);
        const client = await getClientClient();
        const peerBase = String(body.peerBaseUrl || "").replace(/\/+$/, "");
        if (!peerBase) {
          return sendJson(res, 400, { ok: false, error: "peerBaseUrl required" });
        }
        const hookPath = String(body.hookPath || "hooks/wake").replace(/^\/+/, "");
        const endpoint = `/${hookPath}`;
        const peerReq = {
          user: {
            rodit_webhookurl: peerBase.replace(/^https?:\/\//i, ""),
          },
        };
        const payload = body.payload || {
          event: body.text || "wake",
          data: { mode: "now", ...(body.data || {}) },
        };
        const sendOptions = body.sessionRoditId
          ? { sessionRoditId: body.sessionRoditId }
          : {};
        const sdkResult =
          endpoint === "/hooks/wake"
            ? await client.sendWakeHook(payload, peerReq, sendOptions)
            : await client.sendWebhookToEndpoint(payload, endpoint, peerReq, sendOptions);
        return sendJson(res, sdkResult?.isValid ? 200 : 502, {
          ok: sdkResult?.isValid === true,
          url: `${peerBase}${endpoint}`,
          response: sdkResult,
        });
      }

      return sendJson(res, 404, { error: "not found", path });
    } catch (err) {
      const message = err?.message || String(err);
      const status = err?.code === "PAYLOAD_TOO_LARGE" ? 413 : 500;
      if (!res.headersSent) {
        sendJson(res, status, { ok: false, error: message });
      }
    }
  });

  return {
    server,
    host,
    port,
    listen() {
      return new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(port, host, () => {
          server.off("error", reject);
          resolve({ host, port });
        });
      });
    },
    close() {
      return new Promise((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()));
      });
    },
  };
}

export async function main(argv = process.argv.slice(2)) {
  const host = DEFAULT_HOST;
  let port = DEFAULT_PORT;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--port" && argv[i + 1]) port = Number(argv[++i]);
    if (argv[i] === "--host" && argv[i + 1]) {
      /* localhost only — ignore widen attempts */
      i++;
    }
  }
  const svc = createAuthServer({ host, port });
  const addr = await svc.listen();
  console.error(
    JSON.stringify({
      ok: true,
      listening: `http://${addr.host}:${addr.port}`,
      note: "localhost-only IdentyClaw auth sidecar",
    })
  );
  return svc;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    console.error(JSON.stringify({ ok: false, error: err.message || String(err) }));
    process.exit(1);
  });
}
