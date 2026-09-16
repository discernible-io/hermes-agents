import { describe, it } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { createAuthServer } from "../src/server.mjs";
import { buildAudienceRodit } from "../src/lib/rodit.mjs";

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
