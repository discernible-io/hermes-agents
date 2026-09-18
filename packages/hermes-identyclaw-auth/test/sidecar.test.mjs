import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createAuthServer } from "../src/server.mjs";
import {
  buildAudienceRodit,
  resolveInboundAudience,
} from "../src/lib/rodit.mjs";

describe("buildAudienceRodit", () => {
  it("stamps owner_id and subject URL like OpenClaw inbound", () => {
    const rodit = buildAudienceRodit({
      audience: "owner-abc",
      issuer: "https://agent.example.com",
    });
    assert.equal(rodit.owner_id, "owner-abc");
    assert.equal(rodit.token_id, "a2a-inbound");
    assert.equal(
      rodit.metadata.subjectuniqueidentifier_url,
      "https://agent.example.com"
    );
  });
});

describe("resolveInboundAudience", () => {
  it("falls back to IDENTYCLAW_JWT_* when passport is unavailable", async () => {
    const prevAud = process.env.IDENTYCLAW_JWT_AUDIENCE;
    const prevIss = process.env.IDENTYCLAW_JWT_ISSUER;
    const prevCred = process.env.NEAR_CREDENTIALS_FILE_PATH;
    const prevSrc = process.env.RODIT_NEAR_CREDENTIALS_SOURCE;
    try {
      delete process.env.NEAR_CREDENTIALS_FILE_PATH;
      delete process.env.RODIT_NEAR_CREDENTIALS_SOURCE;
      delete process.env.IDENTYCLAW_ACCOUNT_ID;
      process.env.IDENTYCLAW_JWT_AUDIENCE = "fallback-owner";
      process.env.IDENTYCLAW_JWT_ISSUER = "https://api.example.com/";
      const resolved = await resolveInboundAudience({});
      assert.equal(resolved.audience, "fallback-owner");
      assert.equal(resolved.issuer, "https://api.example.com");
    } finally {
      if (prevAud === undefined) delete process.env.IDENTYCLAW_JWT_AUDIENCE;
      else process.env.IDENTYCLAW_JWT_AUDIENCE = prevAud;
      if (prevIss === undefined) delete process.env.IDENTYCLAW_JWT_ISSUER;
      else process.env.IDENTYCLAW_JWT_ISSUER = prevIss;
      if (prevCred === undefined) delete process.env.NEAR_CREDENTIALS_FILE_PATH;
      else process.env.NEAR_CREDENTIALS_FILE_PATH = prevCred;
      if (prevSrc === undefined) delete process.env.RODIT_NEAR_CREDENTIALS_SOURCE;
      else process.env.RODIT_NEAR_CREDENTIALS_SOURCE = prevSrc;
    }
  });
});

describe("auth sidecar HTTP surface", () => {
  it("serves /health on localhost without credentials", async () => {
    const svc = createAuthServer({ host: "127.0.0.1", port: 0 });
    await new Promise((resolve, reject) => {
      svc.server.listen(0, "127.0.0.1", () => resolve());
      svc.server.once("error", reject);
    });
    const { port } = svc.server.address();
    try {
      const res = await fetch(`http://127.0.0.1:${port}/health`);
      assert.equal(res.status, 200);
      const body = await res.json();
      assert.equal(body.ok, true);
      assert.equal(body.service, "hermes-identyclaw-auth");
    } finally {
      await new Promise((resolve) => svc.server.close(resolve));
    }
  });

  it("rejects validate_jwt without token", async () => {
    const svc = createAuthServer({ host: "127.0.0.1", port: 0 });
    await new Promise((resolve, reject) => {
      svc.server.listen(0, "127.0.0.1", () => resolve());
      svc.server.once("error", reject);
    });
    const { port } = svc.server.address();
    try {
      const res = await fetch(`http://127.0.0.1:${port}/v1/validate_jwt`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ token: "" }),
      });
      assert.equal(res.status, 401);
      const body = await res.json();
      assert.equal(body.valid, false);
    } finally {
      await new Promise((resolve) => svc.server.close(resolve));
    }
  });

  it("exposes /api/login/timestamp without Passport", async () => {
    const svc = createAuthServer({ host: "127.0.0.1", port: 0 });
    await new Promise((resolve, reject) => {
      svc.server.listen(0, "127.0.0.1", () => resolve());
      svc.server.once("error", reject);
    });
    const { port } = svc.server.address();
    try {
      const res = await fetch(`http://127.0.0.1:${port}/api/login/timestamp`);
      assert.equal(res.status, 200);
      const body = await res.json();
      assert.equal(typeof body.timestamp, "number");
      assert.equal(typeof body.timestamp_iso, "string");
    } finally {
      await new Promise((resolve) => svc.server.close(resolve));
    }
  });

  it("returns 503 from /v1/own_passport without credentials", async () => {
    const prevCred = process.env.NEAR_CREDENTIALS_FILE_PATH;
    const prevSrc = process.env.RODIT_NEAR_CREDENTIALS_SOURCE;
    delete process.env.NEAR_CREDENTIALS_FILE_PATH;
    delete process.env.RODIT_NEAR_CREDENTIALS_SOURCE;
    delete process.env.IDENTYCLAW_ACCOUNT_ID;
    const svc = createAuthServer({ host: "127.0.0.1", port: 0 });
    await new Promise((resolve, reject) => {
      svc.server.listen(0, "127.0.0.1", () => resolve());
      svc.server.once("error", reject);
    });
    const { port } = svc.server.address();
    try {
      const res = await fetch(`http://127.0.0.1:${port}/v1/own_passport`);
      assert.equal(res.status, 503);
      const body = await res.json();
      assert.equal(body.ok, false);
    } finally {
      await new Promise((resolve) => svc.server.close(resolve));
      if (prevCred === undefined) delete process.env.NEAR_CREDENTIALS_FILE_PATH;
      else process.env.NEAR_CREDENTIALS_FILE_PATH = prevCred;
      if (prevSrc === undefined) delete process.env.RODIT_NEAR_CREDENTIALS_SOURCE;
      else process.env.RODIT_NEAR_CREDENTIALS_SOURCE = prevSrc;
    }
  });
});

describe("list_sessions never leaks jwt", () => {
  it("session listing shape omits jwt fields", async () => {
    const { listSessions } = await import("../src/lib/session.mjs");
    const out = listSessions();
    assert.equal(out.ok, true);
    assert.ok(Array.isArray(out.sessions));
    for (const s of out.sessions) {
      assert.equal("jwt" in s, false);
      assert.equal("jwt_token" in s, false);
    }
  });
});
