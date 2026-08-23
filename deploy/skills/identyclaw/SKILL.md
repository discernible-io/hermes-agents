---
name: identyclaw
description: >-
  Use when enrolling an IdentyClaw Passport, obtaining an API session (JWT),
  creating or verifying HOLA peer handshake lines, resolving Passport IDs,
  discovering agents, or reading IdentyClaw API documentation. Requires a NEAR
  implicit account and Passport mint on api.identyclaw.com. On Hermes, call the
  host helper `idcp` (secrets under hermes-agents-app/secrets/).
version: 1.1.0
author: Discernible IO
license: MIT
compatibility: >-
  Hermes Agent. Secrets in sibling hermes-agents-app. Host helper: idcp.
metadata:
  hermes:
    tags: [identity, hola, near, passport, api, enrollment, verification, rodit]
    related_skills: []
---

# IdentyClaw (Hermes)

**Base URL:** `https://api.identyclaw.com`  
**Docs MCP:** `https://api.identyclaw.com/mcp` (`doc:skills`, `doc:reference:agent-frameworks`)

Hermes uses the **host login** path (not OpenClaw plugins). Call the `idcp` CLI — do not hand-roll Ed25519 login in prompts.

## Layout (this host)

| Path | Role |
|------|------|
| `hermes-agents/deploy/` | Synced scripts (`idcp/`) |
| `hermes-agents-app/secrets/near-credentials/*.json` | NEAR key |
| `hermes-agents-app/secrets/identyclaw/jwt-*.txt` | Cached JWT per API host |
| `hermes-agents-app/skills/identity/identyclaw/` | This skill |

Inside the Hermes container, app dir is `/opt/data` and `idcp` is on PATH when installed.

## Agent-facing ops (`idcp`)

| Op | Command | Returns |
|----|---------|---------|
| ensure_session | `idcp ensure_session [--force] [--base URL]` | metadata only (`ok`, `tokenId`, `jwt_length`) — **never** full JWT |
| list_sessions | `idcp list_sessions` | cached hosts; no JWTs |
| me | `idcp me` | Passport identity |
| request | `idcp request METHOD /api/path [--body JSON]` | host injects Bearer |
| create_hola | `idcp create_hola [--recipient MUNDO\|peerTokenId]` | HOLA string |
| verify_hola | `idcp verify_hola --hola '…' [--expected MUNDO]` | verify JSON |

## Rules

- Prefer `idcp` over inventing signatures or pasting JWTs into chat.
- One JWT **per API host** (home vs federated): `idcp ensure_session --base https://peer…`
- After inbound `verify_hola` → `verified: true`, immediately `create_hola` and reply on the **same channel**.
- Verify before execute on delegated work.

## Enrollment (once)

```bash
idcp enroll
# Human: https://purchase.identyclaw.com with account_id
idcp ensure_session
idcp me
```

## Day-to-day

```bash
idcp ensure_session
idcp verify_hola --hola 'HOLA/…'
idcp create_hola --recipient MUNDO
idcp request GET /api/agents
idcp request GET /api/identity/token/<peerTokenId>/full
```

Federated peers (no API key — remint a JWT for that host):

```bash
idcp ensure_session --base https://api.lastcradle.io
idcp request GET /api/token/claims --base https://api.lastcradle.io
```
