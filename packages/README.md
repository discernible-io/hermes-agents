# IdentyClaw packages for Hermes

Publishable components so **stock Nous Hermes** can add IdentyClaw Passport
without this fork’s Podman wrapper (`deploy/hermes.sh`). Same packages power
the fork via `./hermes.sh identyclaw-peer-install`.

| Package | Role |
|---------|------|
| [`hermes-identyclaw-auth`](hermes-identyclaw-auth/) | `idcp` CLI + localhost RODiT auth sidecar (`@rodit/rodit-auth-be`) |
| [`hermes-identyclaw-a2a`](hermes-identyclaw-a2a/) | Platform overlay (`a2a-platform`) — Passport JWT + `/api/login*` |
| [`hermes-identyclaw-webhooks`](hermes-identyclaw-webhooks/) | Platform — RODiT `/hooks/wake` + `/hooks/agent` + `send_rodit_webhook` |

Agent skill (not an npm package): copy from
[`../deploy/skills/identyclaw/`](../deploy/skills/identyclaw/) into
`$HERMES_HOME/skills/identity/identyclaw/`.

Requires **Node ≥ 22.19**. Secrets and JWT cache go under the app dir resolved by
`idcp` (`IDENTYCLAW_HOME` → `HERMES_APP_DIR` → `HERMES_HOME`, else a sibling
`hermes-agents-app/` when running from this monorepo).

---

## Operator path (this fork)

```bash
./deploy/hermes.sh identyclaw-peer-install
./deploy/hermes.sh identyclaw-auth-start
./deploy/hermes.sh start
```

See root [README §5b](../README.md#5b-passport-peer-stack-opt-in--a2a--signed-hooks).

---

## Stock Hermes (vanilla install)

Keep [upstream Hermes](https://github.com/NousResearch/hermes-agent). You only
need a checkout (or release) of these packages — not the Podman app layout.

```bash
export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
# idcp prefers IDENTYCLAW_HOME when set:
# export IDENTYCLAW_HOME="$HERMES_HOME"
```

| Path | Role |
|------|------|
| `$HERMES_HOME/secrets/near-credentials/` | NEAR key JSON (`idcp enroll`) |
| `$HERMES_HOME/secrets/identyclaw/` | Per-host JWT cache (never print to the model) |
| `$HERMES_HOME/bin/idcp` | CLI shim on PATH for gateway + sandboxes |
| `$HERMES_HOME/skills/identity/identyclaw/` | Agent skill |
| `$HERMES_HOME/plugins/a2a-platform/` | Tier 2 only |
| `$HERMES_HOME/plugins/identyclaw-webhooks/` | Tier 2 only |

### Tier 1 — Call federated peers (usual need)

Passport as *client*. No sidecar, no A2A/hooks plugins, no `WEBHOOK_SECRET`.

```bash
cd packages/hermes-identyclaw-auth
npm install --omit=dev
mkdir -p "$HERMES_HOME/bin" "$HERMES_HOME/skills/identity/identyclaw"
ln -sf "$(pwd)/bin/idcp.mjs" "$HERMES_HOME/bin/idcp"
cp -a ../../deploy/skills/identyclaw/. "$HERMES_HOME/skills/identity/identyclaw/"
# Put $HERMES_HOME/bin on PATH (CLI, gateway process, docker/SSH sandboxes).

idcp enroll
# Human: https://purchase.identyclaw.com — recipient = printed account_id
idcp ensure_session
idcp me
idcp ensure_session --base https://api.lastcradle.io
idcp request GET /api/token/claims --base https://api.lastcradle.io
```

- One JWT **per API host**. A home JWT is not accepted at a peer.
- Prefer `idcp` over inventing signatures or pasting tokens into chat.
- Optional: `hermes mcp add IdentyClawDocs --url https://api.identyclaw.com/mcp`

Package detail: [`hermes-identyclaw-auth/README.md`](hermes-identyclaw-auth/README.md).

### Tier 2 — Be a Passport peer (optional)

Only if other Passport agents should A2A or RODiT-wake this Hermes. Requires
Tier 1, then:

```bash
REPO=…/hermes-agents   # this repo (or packages release root)
mkdir -p "$HERMES_HOME/plugins"
cp -a "$REPO/packages/hermes-identyclaw-a2a/." \
  "$HERMES_HOME/plugins/a2a-platform/"
cp -a "$REPO/packages/hermes-identyclaw-webhooks/." \
  "$HERMES_HOME/plugins/identyclaw-webhooks/"
```

Enable plugins in `$HERMES_HOME/config.yaml`:

```yaml
plugins:
  enabled:
    - a2a-platform
    - identyclaw-webhooks
  entries:
    a2a-platform:
      enabled: true
      allow_tool_override: true
    identyclaw-webhooks:
      enabled: true
```

| Variable | Purpose |
|----------|---------|
| `NEAR_CREDENTIALS_FILE_PATH` | Absolute path to NEAR key JSON (JWT `aud` = passport `owner_id`) |
| `A2A_PUBLIC_URL` | Public HTTPS base for A2A Agent Card |
| `IDENTYCLAW_AUTH_PORT` | Sidecar (default `9910`) |
| `IDENTYCLAW_HOOKS_PORT` | `/hooks/*` (default `9911`) |
| `IDENTYCLAW_JWT_AUDIENCE` | Optional fallback only — prefer RoditClient |

```bash
NEAR_CREDENTIALS_FILE_PATH=… \
  node "$REPO/packages/hermes-identyclaw-auth/bin/sidecar.mjs" --port 9910
```

Point Passport `metadata.webhook_url` (and `A2A_PUBLIC_URL`) at your public
HTTPS base. Restart the gateway so plugins load.

Does **not** replace Hermes HMAC `/webhooks/{route}` — that path still uses
`WEBHOOK_SECRET` if you enable it. Details:
[`hermes-identyclaw-a2a/README.md`](hermes-identyclaw-a2a/README.md),
[`hermes-identyclaw-webhooks/README.md`](hermes-identyclaw-webhooks/README.md).

### What not to do

- Do not fork Hermes core or bake Passport into the Nous image for this.
- Do not put IdentyClaw into Agent Plugins as product surface; these are host
  packages + optional platform plugins.
- Do not send a home JWT to a federated peer.
