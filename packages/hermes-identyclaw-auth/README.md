# @identyclaw/hermes-identyclaw-auth

IdentyClaw Passport helpers for Hermes: **`idcp` CLI** (host login / HOLA) plus a **localhost auth sidecar** wrapping `@rodit/rodit-auth-be`.

## Install (stock Hermes)

Point secrets at your Hermes home (not the fork’s sibling app dir):

```bash
export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
npm install --omit=dev
mkdir -p "$HERMES_HOME/bin"
ln -sf "$(pwd)/bin/idcp.mjs" "$HERMES_HOME/bin/idcp"
# ensure $HERMES_HOME/bin is on PATH
idcp enroll
idcp ensure_session
```

Full Tier 1 / Tier 2 playbook: [`../README.md`](../README.md).

Sidecar (for platform plugins):

```bash
NEAR_CREDENTIALS_FILE_PATH=/path/to/near.json \
IDENTYCLAW_JWT_AUDIENCE=<passport owner_id> \
node bin/sidecar.mjs --port 9910
```

## Sidecar routes

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/health` | liveness |
| POST | `/v1/validate_jwt` | Passport JWT → `token_id` |
| POST | `/v1/login_server` | outbound peer login |
| POST | `/v1/authenticate_webhook` | Ed25519 webhook verify |
| GET/POST | `/api/login/timestamp`, `/api/login` | peer inbound login |

Binds **127.0.0.1** only. Never prints full JWTs from the CLI.
