/**
 * Lazy wrappers around @rodit/rodit-auth-be — same contract OpenClaw plugins use.
 */
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { ensureRoditCredentialEnv } from "./paths.mjs";

const require = createRequire(import.meta.url);

let _RoditClient = null;
let _serverClientPromise = null;
let _clientClientPromise = null;
let _authModulePromise = null;

function loadRoditAuthBe() {
  if (!_RoditClient) {
    const mod = require("@rodit/rodit-auth-be");
    _RoditClient = mod.RoditClient;
  }
  return { RoditClient: _RoditClient, ...require("@rodit/rodit-auth-be") };
}

export function applyLoginMode(mode = "promiscuous") {
  process.env.SECURITY_OPTIONS_LOGIN_MODE = mode;
}

export async function getServerClient(credentialsPath = null) {
  ensureRoditCredentialEnv(credentialsPath);
  applyLoginMode(process.env.SECURITY_OPTIONS_LOGIN_MODE || "promiscuous");
  if (!_serverClientPromise) {
    const { RoditClient } = loadRoditAuthBe();
    _serverClientPromise = RoditClient.create({ role: "server" });
  }
  return _serverClientPromise;
}

export async function getClientClient(credentialsPath = null) {
  ensureRoditCredentialEnv(credentialsPath);
  if (!_clientClientPromise) {
    const { RoditClient } = loadRoditAuthBe();
    _clientClientPromise = RoditClient.create({ role: "client" });
  }
  return _clientClientPromise;
}

export async function getAuthServices(credentialsPath = null) {
  ensureRoditCredentialEnv(credentialsPath);
  if (!_authModulePromise) {
    const pkgRoot = dirname(require.resolve("@rodit/rodit-auth-be"));
    _authModulePromise = Promise.resolve(
      require(join(pkgRoot, "lib/auth/authentication.js"))
    );
  }
  return _authModulePromise;
}

export function loadValidateJwt() {
  const { validate_jwt_token_be } = loadRoditAuthBe();
  return validate_jwt_token_be;
}

export function extractWebhookSignerKey(headers, stateManager) {
  const { extractWebhookSignerKey: extract } = loadRoditAuthBe();
  return extract(headers, stateManager);
}

export function extractWebhookSessionId(opts) {
  const { extractWebhookSessionId: extract } = loadRoditAuthBe();
  return extract(opts);
}

/** Reset cached clients (tests only). */
export function resetRoditClientsForTests() {
  _serverClientPromise = null;
  _clientClientPromise = null;
  _authModulePromise = null;
}

/**
 * Build the audience rodit stub OpenClaw uses for inbound JWT validation.
 * aud = this agent's passport owner_id; issuer = subjectuniqueidentifier_url.
 */
export function buildAudienceRodit({ audience, issuer }) {
  return {
    token_id: "a2a-inbound",
    owner_id: audience,
    metadata: {
      subjectuniqueidentifier_url: issuer,
    },
  };
}

/**
 * Own passport via RoditClient.getConfigOwnRodit() — same path as OpenClaw
 * `src/auth/rodit-own-config.ts`. Audience for inbound P2P JWTs is
 * `own_rodit.owner_id` (NEAR account hex), never a hardcoded env string.
 */
export async function getRoditOwnConfig(credentialsPath = null) {
  ensureRoditCredentialEnv(credentialsPath);
  if (!process.env.NEAR_CREDENTIALS_FILE_PATH?.trim() && !process.env.IDENTYCLAW_ACCOUNT_ID) {
    throw new Error(
      "RODiT credentials not configured: set NEAR_CREDENTIALS_FILE_PATH (secrets/near-credentials/*.json)"
    );
  }
  const client = await getClientClient(credentialsPath);
  const config = await client.getConfigOwnRodit();
  if (!config?.own_rodit || !config.own_rodit_bytes_private_key) {
    throw new Error("RODiT own passport configuration is not initialized");
  }
  return config;
}

/** Public passport fields for Agent Card / Python security context. */
export async function resolveOwnPassport(credentialsPath = null) {
  const config = await getRoditOwnConfig(credentialsPath);
  const own = config.own_rodit;
  const metadata = own.metadata || {};
  return {
    ok: true,
    token_id: String(own.token_id || "").trim() || null,
    owner_id: String(own.owner_id || "").trim() || null,
    issuer: String(metadata.subjectuniqueidentifier_url || "")
      .trim()
      .replace(/\/+$/, "") || null,
    webhook_url: String(metadata.webhook_url || "").trim() || null,
  };
}

/**
 * Resolve inbound JWT aud/iss. Prefer RoditClient passport (authoritative);
 * explicit args / IDENTYCLAW_JWT_* only when passport probe fails (tests / boot).
 */
export async function resolveInboundAudience({ audience, issuer, credentialsPath = null } = {}) {
  let aud = "";
  let iss = "";
  try {
    const passport = await resolveOwnPassport(credentialsPath);
    aud = (passport.owner_id || "").trim();
    iss = (passport.issuer || "").trim().replace(/\/+$/, "");
  } catch {
    /* fall through to args / env */
  }
  if (!aud) aud = (audience || process.env.IDENTYCLAW_JWT_AUDIENCE || "").trim();
  if (!iss) {
    iss = (
      issuer ||
      process.env.IDENTYCLAW_JWT_ISSUER ||
      process.env.A2A_PUBLIC_URL ||
      ""
    )
      .trim()
      .replace(/\/+$/, "");
  }
  return { audience: aud, issuer: iss };
}

export async function validateInboundJwt(token, { audience, issuer, logLevel } = {}) {
  if (!token) return { valid: false, reason: "missing_token" };
  const { audience: aud, issuer: iss } = await resolveInboundAudience({
    audience,
    issuer,
  });
  if (!aud) {
    return { valid: false, reason: "missing_audience" };
  }
  if (logLevel) process.env.LOG_LEVEL = logLevel;
  ensureRoditCredentialEnv();
  const validate = loadValidateJwt();
  try {
    const result = await validate(token, buildAudienceRodit({ audience: aud, issuer: iss }), {
      enforceSessionRegistration: false,
    });
    if (result?.valid && result.payload) {
      const payload = result.payload;
      const peer = result.peer_rodit || {};
      const tokenId =
        payload.token_id ||
        payload.rodit_id ||
        peer.token_id ||
        null;
      return {
        valid: true,
        payload,
        peer_rodit: peer,
        token_id: tokenId,
        identity: tokenId ? String(tokenId) : null,
      };
    }
  } catch {
    /* mismatch */
  }
  return { valid: false, reason: "invalid_token" };
}

export async function loginServerToPeer({ apiEndpoint, credentialsPath = null } = {}) {
  const client = await getClientClient(credentialsPath);
  const opts = apiEndpoint ? { apiEndpoint } : {};
  const result = await client.login_server(opts);
  if (!result?.jwt_token || result.success === false) {
    throw new Error(result?.error || "login_server returned no jwt_token");
  }
  return {
    ok: true,
    jwt_token: result.jwt_token,
    jwt_length: result.jwt_token.length,
    token_id: result.token_id || result.roditid || null,
    // never return jwt to model-facing surfaces from Python without care —
    // sidecar callers (platform plugins) need the token for Authorization.
  };
}

/** Express-like res wrapper for rodit-auth-be login_client. */
export function wrapExpressLikeResponse(res, sendJson) {
  let statusCode = 200;
  const wrapped = res;
  wrapped.status = (code) => {
    statusCode = code;
    res.statusCode = code;
    return {
      json: (payload) => {
        if (!res.headersSent) sendJson(res, statusCode, payload);
      },
    };
  };
  wrapped.json = (payload) => {
    if (!res.headersSent) sendJson(res, statusCode, payload);
  };
  return wrapped;
}
