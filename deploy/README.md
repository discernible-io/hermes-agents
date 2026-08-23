# Hermes Agent (Podman) — `deploy/` wrapper

Host-side **Podman + IdentyClaw** operator scripts that live inside this fork at
`deploy/`. Upstream Hermes agent source is the rest of the repository
([`discernible-io/hermes-agents`](https://github.com/discernible-io/hermes-agents),
from [`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent)).

**Secrets, memory, skills, and config stay in the sibling app directory** so you
can sync this checkout without carrying runtime state.

| Path | Purpose |
|------|---------|
| `~/hermes-agents/` | This fork (upstream source + `deploy/` wrapper) |
| `~/hermes-agents/deploy/` | Podman scripts, `idcp/`, nginx sidecar, IdentyClaw skill |
| `~/hermes-agents-app/` | Runtime home (mounted at `/opt/data`) — `env.local`, `.env`, `config.yaml`, `skills/`, `memories/`, `sessions/` |

Override the app root with `HERMES_APP_DIR=/custom/path`.

## Secret and layout map

One store per concern (aligned with discernible-io/docs configuration + CI/CD standards):

| Store | Path | Holds | How gateway sees it |
|-------|------|-------|---------------------|
| **Non-secrets** | `~/hermes-agents-app/env.local` | Ports, `HERMES_DEPLOY_MODE`, `HERMES_PUBLIC_HOST`, email display prefs | Sourced by `hermes.sh` on the host only |
| **Secrets** | `~/hermes-agents-app/.env` | API keys, `TELEGRAM_*`, `WEBHOOK_SECRET`, auth tokens | `podman run --env-file …/.env` (never `-e KEY=secret`) |
| **File secrets** | `~/hermes-agents-app/secrets/` | Himalaya pass helpers, NEAR/IdentyClaw creds | Bind-mounted under `/opt/data/secrets` |
| **Config** | `~/hermes-agents-app/config.yaml` | Non-secret Hermes settings; webhook host/port/routes only | Mounted as HERMES_HOME — **no secrets** |
| **TLS** | `~/hermes-agents-app/certs/` | `fullchain.pem` / `privkey.pem` (LE or self-signed) | nginx sidecar `ro` mount; UID 101 via `podman unshare` |
| **Nginx** | `~/hermes-agents-app/nginx/` | Rendered `nginx.conf` + copied `inc/` | All sidecar binds under APP_DIR (not the git clone) |

`./hermes.sh start` syncs any secret keys still present in `env.local` into `.env` when missing there, then starts with `--env-file`. Prefer editing `.env` directly for new secrets. `WEBHOOK_SECRET` must not appear in `config.yaml`.

Rootless Podman linger is enabled on every start (`scripts/ensure-podman-linger.sh`; set `SKIP_LINGER=1` to skip).

## Quick start

```bash
cd ~/hermes-agents/deploy
chmod +x hermes.sh
./hermes.sh init          # creates ~/hermes-agents-app + env.local, pulls image
./hermes.sh setup         # interactive wizard only (no gateway / no s6)
./hermes.sh start         # detached gateway, --restart always
./hermes.sh status
```

Run **setup and start as separate commands** (do not chain them). Setup is interactive and must finish before start.

Uses rootless **Podman** (same host pattern as `identyclaw-agents`). Image: `docker.io/nousresearch/hermes-agent:latest`.

AlmaLinux / RHEL: `podman-restart.service` only restarts containers with policy **`always`** (not `unless-stopped`).

## Commands

| Command | What it does |
|---------|----------------|
| `./hermes.sh init` | App layout + pull image |
| `./hermes.sh setup` | Interactive `hermes setup` into the app volume |
| `./hermes.sh start` | Recreate gateway container |
| `./hermes.sh stop` | Stop and remove container |
| `./hermes.sh status` | Paths + container status |
| `./hermes.sh logs` | Follow container logs |
| `./hermes.sh pull` | Pull newer image (then `start`) |
| `./hermes.sh chat` | Ephemeral interactive CLI against the app dir |
| `./hermes.sh exec -- …` | Run a command in the live container (or one-shot) |
| `./hermes.sh idcp-install` | Install IdentyClaw `idcp` helper + skill into app dir |
| `./hermes.sh idcp …` | Passport ops (`enroll`, `ensure_session`, `create_hola`, …) |
| `./hermes.sh himalaya-install` | Install Himalaya CLI + Migadu config into app dir |
| `./hermes.sh himalaya-password` | Store Migadu IMAP/SMTP password |
| `./hermes.sh himalaya-test` | IMAP smoke test (`envelope list`) |
| `./hermes.sh generate-certs` | Self-signed TLS PEMs for pod ingress (`--force` to replace) |
| `./hermes.sh build-nginx` | Build local `hermes-nginx` sidecar image |

## Webhooks (pod + nginx TLS sidecar)

Hermes has a built-in webhook adapter (`POST /webhooks/<route>`, HMAC via `WEBHOOK_SECRET`).
This wrapper can expose it behind an **nginx TLS sidecar** in a dedicated Podman pod
(same pattern as `identyclaw-agents`, but a **separate** stack — not the OpenClaw 7443/9443 pod).

| Mode | Behavior |
|------|----------|
| `HERMES_DEPLOY_MODE=standalone` (default) | Single gateway container; API on `HERMES_API_PORT`; no public webhooks |
| `HERMES_DEPLOY_MODE=pod` | Pod `hermes-agent-pod`: `hermes` + `hermes-nginx`; HTTPS ingress; webhooks forced on |

Auth is Hermes **HMAC** via `WEBHOOK_SECRET` in `.env` (not IdentyClaw RODiT; not `config.yaml`). nginx only terminates TLS and proxies `/webhooks/`.

Host publish: Telegram webhook on **8443** (Telegram Bot API only accepts inbound webhooks on 443, 80, 88, or 8443). Operator API stays on 11642. Override `HERMES_TELEGRAM_PORT` / `HERMES_INGRESS_PORT` in `env.local` when 8443 is already taken on the host.

| Host port | Maps to | Use |
|-----------|---------|-----|
| `8443` | container `8443` (standalone) or nginx TLS (pod) | Telegram webhook (`/telegram`) |
| `11642` | container `8642` | Operator API |
| `11919` | container `9119` | Dashboard (optional) |

```bash
# in hermes-agents-app/env.local (non-secrets)
HERMES_DEPLOY_MODE=pod
HERMES_PUBLIC_HOST=hermes.example.com
HERMES_INGRESS_PORT=8443
HERMES_API_PORT=11642

# in hermes-agents-app/.env (secrets — --env-file)
WEBHOOK_SECRET=$(openssl rand -hex 32)
WEBHOOK_ENABLED=true
WEBHOOK_PORT=8644
TELEGRAM_WEBHOOK_URL=https://hermes.example.com:8443/telegram
TELEGRAM_WEBHOOK_SECRET=$(openssl rand -hex 32)

./hermes.sh generate-certs   # or install LE PEMs into certs/
./hermes.sh build-nginx
./hermes.sh start
curl -k "https://${HERMES_PUBLIC_HOST}:${HERMES_INGRESS_PORT}/health"
# Point GitHub/etc at https://hermes.example.com:8443/webhooks/<route>
# Manage routes: ./hermes.sh exec -- hermes webhook subscribe …
```

Auth is Hermes **HMAC** via `WEBHOOK_SECRET` in `.env` (not IdentyClaw RODiT; not `config.yaml`). nginx only terminates TLS and proxies `/webhooks/`.

Layout under the app volume (pod mode):

| Path | Role |
|------|------|
| `certs/` | `fullchain.pem` + `privkey.pem` |
| `nginx/nginx.conf` | Rendered from env (host + ingress port) |
| `nginx/inc/` | Copied from `deploy/nginx/inc` on start (APP_DIR bind only) |
| `logs/nginx/` | Sidecar access/error logs |

Operator API remains on `http://127.0.0.1:${HERMES_API_PORT}` (not on the public hostname).

## IdentyClaw Passport (RODiT)

Host-login path (portable brief — not OpenClaw plugins). Secrets stay in the **app** directory:

| Path | Role |
|------|------|
| `hermes-agent/deploy/idcp/` | Synced helper CLI |
| `hermes-agents-app/secrets/near-credentials/` | NEAR key JSON |
| `hermes-agents-app/secrets/identyclaw/` | JWT cache (per API host) |
| `hermes-agents-app/skills/identity/identyclaw/` | Agent skill |

```bash
./hermes.sh idcp-install
./hermes.sh idcp enroll                 # gennearaccount → secrets/near-credentials
# Human: https://purchase.identyclaw.com with account_id
./hermes.sh idcp ensure_session
./hermes.sh idcp me
./hermes.sh start                       # recreates gateway with /opt/idcp mount
```

Home JWT is **not** accepted on federated peers. Remint per `apiEndpoint` (no API key):

```bash
./hermes.sh idcp ensure_session --base https://api.lastcradle.io
./hermes.sh idcp request GET /api/token/claims --base https://api.lastcradle.io
```

Peer template: [discernible-io/api-idc](https://github.com/discernible-io/api-idc). Full enrollment + federation walkthrough: [README.md](../README.md#identyclaw-passport-discernible).

Agent ops (also available as `idcp` inside the container):

- `ensure_session` / `list_sessions` / `me`
- `request METHOD /api/path`
- `create_hola` / `verify_hola`

Optional docs MCP: `hermes mcp add IdentyClawDocs --url https://api.identyclaw.com/mcp`

Packaging notes and how this wrapper compares to stock
[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent): see [ADDON-PLAN.md](./ADDON-PLAN.md).
Upstream ask for generic `$HERMES_HOME/bin` sandbox mounts:
[NousResearch/hermes-agent#83805](https://github.com/NousResearch/hermes-agent/pull/83805).

## Egress / terminal sandboxes

By default `./hermes.sh start` (and setup) write `proxy.enabled: false` into
`hermes-agents-app/config.yaml`. That lives on the volume, so image rebuilds keep
terminal/`idcp` sandboxes working without iron-proxy.

Docker terminal backend: the gateway dual-mounts the app dir at its **host path**
and sets `HERMES_HOME` to that path so nested `docker run -v` resolves on the
host Podman (avoids exit 126 / `mkdir /opt/data: permission denied`). Start also
writes `terminal.docker_volumes` for idcp + secrets.

To enable iron-proxy later: set `HERMES_EGRESS=1` in `env.local`, run
`./hermes.sh exec -- hermes egress setup`, then `./hermes.sh start`.

## Himalaya email (Migadu)

Agent mailbox for read/write from terminal sandboxes (not the Email gateway adapter).

```bash
# in hermes-agents-app/env.local
HERMES_EMAIL=hermes@agenthood.me
HERMES_EMAIL_DISPLAY_NAME=Hermes Trimegisto
# HERMES_MAIL_PASSWORD=…   # or pass interactively:

./hermes.sh himalaya-install
./hermes.sh himalaya-password
./hermes.sh himalaya-test
./hermes.sh start            # refreshes docker_volumes + SMTP IPv4 pin

# If SMTP still times out after a pin change: ExtraHosts are immutable on
# long-lived sandboxes. himalaya-test / ensure_sandbox_volumes remove
# hermes-* containers whose smtp.migadu.com pin disagrees with MIGADU_SMTP_IPV4.
# Or: docker rm -f $(docker ps -aq --filter label=hermes-agent=1)
```

Layout under the app volume:

| Path | Role |
|------|------|
| `bin/himalaya` | CLI binary |
| `secrets/himalaya/` | IMAP/SMTP password helpers |
| `sandboxes/docker/default/home/.config/himalaya/` | config.toml |
| `sandboxes/docker/default/workspace/scripts/himalaya-*.sh` | headless helpers |
| `skills/email/himalaya/SKILL.md` | skill override (pre-configured) |

In chat: ask Hermes to check the inbox with himalaya / `sh scripts/himalaya-inbox.sh`.

## Updates

Do **not** use `hermes update` inside the container. Pull and recreate:

```bash
./hermes.sh pull && ./hermes.sh start
```

## Ownership note (rootless Podman)

While the gateway runs, the image owns files in `~/hermes-agents-app` as the container `hermes` UID. Do **not** chown that tree back to the host while it is running (`.env` becomes unreadable and the gateway crashes).

- Edit secrets / config on the host after `./hermes.sh stop` (stop restores host ownership), or use `./hermes.sh exec -- …` against the live container.
- `./hermes.sh own host` also reclaims ownership when stopped.

## Migrating from older names

This GitHub repo is [`discernible-io/hermes-agents`](https://github.com/discernible-io/hermes-agents). Clone into `~/hermes-agents`. Runtime state stays in `~/hermes-agents-app/`.

If you already cloned the previous GitHub name (`discernible-io/hermes-agent` → `~/hermes-agent`):

```bash
mv ~/hermes-agent ~/hermes-agents   # optional; local folder name is yours
git -C ~/hermes-agents remote set-url origin git@github.com:discernible-io/hermes-agents.git
```

If you already have runtime state under the previous app-dir name (`~/hermes-agent-app`):

```bash
mv ~/hermes-agent-app ~/hermes-agents-app
# or: export HERMES_APP_DIR=~/hermes-agent-app
cd ~/hermes-agents/deploy && ./hermes.sh status
```
