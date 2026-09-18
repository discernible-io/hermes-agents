# Hermes identyclaw-a2a (Passport JWT overlay)

Last-writer-wins overlay for bundled `a2a-platform`. Inbound identity is a
Passport JWT (`token_id` via sidecar `validate_jwt`). Outbound calls
`login_server` against the peer base URL. **Do not set `A2A_BEARER_TOKEN`
for this peer.**

## Install on this fork

```bash
./hermes.sh identyclaw-peer-install
# IDENTYCLAW_JWT_AUDIENCE = this agent's Passport owner_id
# A2A_PUBLIC_URL = https://identyclaw-concierge.identyclaw.com:7443
./hermes.sh start   # in-pod sidecar on 127.0.0.1:9910
```

## Install on stock Hermes

Copy this directory to `$HERMES_HOME/plugins/a2a-platform/` and enable it:

```yaml
plugins:
  enabled: [a2a-platform]
  entries:
    a2a-platform:
      allow_tool_override: true
platforms:
  a2a:
    enabled: true
a2a_agents:
  bdshbmlhsdbh:
    url: "https://hermes.dihola.io:10443/a2a"
    timeout: 120
```

No `auth: { type: bearer, token: ... }`. Empty / `login_server` is the match.

Run the sidecar from `sidecar/` (`npm install` then `node server.mjs`) on
`127.0.0.1:9910` with `NEAR_CREDENTIALS_FILE_PATH` and
`IDENTYCLAW_JWT_AUDIENCE`.

## Match checks

- `GET /a2a` → 200
- `GET /api/login/timestamp` → 200 (`timestamp_iso`)
- `POST /a2a` with no JWT → 401
- `POST /a2a` with a Passport JWT (from `login_server` to this base) → task completes
- A static bearer is **not** required

Agent Card (`GET /.well-known/agent-card.json` and
`/a2a/.well-known/agent-card.json`) includes:

```json
"extensions": {
  "identyclaw": {
    "auth": "passport-jwt",
    "login": {
      "timestamp": "/api/login/timestamp",
      "login": "/api/login"
    }
  }
}
```
