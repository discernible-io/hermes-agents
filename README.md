# IdentyClaw for Hermes

Umbrella repo: rootless Podman operator (`deploy/`) plus helpers for
[IdentyClaw Passport](https://purchase.identyclaw.com) on stock
[Nous Research Hermes Agent](https://github.com/NousResearch/hermes-agent).

Passport plugins are separate public repos. Hermes core stays upstream — install
plugins with the official Hermes CLI documented by Nous:
[Plugins](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins).

| Piece | Repo |
|---|---|
| Auth / `idcp` | [discernible-io/hermes-identyclaw-auth](https://github.com/discernible-io/hermes-identyclaw-auth) |
| A2A plugin | [discernible-io/hermes-identyclaw-a2a](https://github.com/discernible-io/hermes-identyclaw-a2a) |
| Webhooks plugin | [discernible-io/hermes-identyclaw-webhook](https://github.com/discernible-io/hermes-identyclaw-webhook) |
| [`install.sh`](install.sh) | Optional one-shot installer into `$HERMES_HOME` |
| [`deploy/`](deploy/README.md) | Optional Podman operator for this host |

## Install on an existing Hermes agent (official Nous CLI)

Prerequisite: Hermes already installed from
[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
([docs](https://hermes-agent.nousresearch.com/)). `$HERMES_HOME` defaults to
`~/.hermes`.

### Tier 1 — Call federated peers (Passport as client)

Auth is a Node package (`idcp` + skill), not a Hermes `plugin.yaml` plugin:

```bash
export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
git clone https://github.com/discernible-io/hermes-identyclaw-auth.git
cd hermes-identyclaw-auth
npm install --omit=dev
mkdir -p "$HERMES_HOME/bin" "$HERMES_HOME/skills/identity/identyclaw"
ln -sf "$(pwd)/bin/idcp.mjs" "$HERMES_HOME/bin/idcp"
cp -a skills/identyclaw/. "$HERMES_HOME/skills/identity/identyclaw/"
# Put $HERMES_HOME/bin on PATH for the Hermes CLI, gateway, and terminal sandboxes.

idcp enroll
# Mint Passport at https://purchase.identyclaw.com (recipient = printed account_id)
idcp ensure_session
idcp me
```

Optional docs MCP: `hermes mcp add IdentyClawDocs --url https://api.identyclaw.com/mcp`

### Tier 2 — Be a Passport peer (A2A + signed /hooks/*)

Requires Tier 1, then install the platform plugins with Hermes’s official plugin
installer ([Plugins guide](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins)):

```bash
hermes plugins install discernible-io/hermes-identyclaw-a2a --enable
hermes plugins install discernible-io/hermes-identyclaw-webhook --enable
```

`a2a-platform` replaces bundled A2A tools — grant `tools.override` when Hermes
prompts (or set `plugins.entries.a2a-platform.allow_tool_override: true` /
`granted_capabilities: [tools.override]` in `$HERMES_HOME/config.yaml`).

Verify and manage with the same Nous CLI:

```bash
hermes plugins list
hermes plugins capabilities a2a-platform
```

Then start the auth sidecar and restart the Hermes gateway:

```bash
export NEAR_CREDENTIALS_FILE_PATH="$(ls "$HERMES_HOME"/secrets/near-credentials/*.json | head -1)"
export A2A_PUBLIC_URL="https://your-public-host"   # Agent Card / discovery URL
node /path/to/hermes-identyclaw-auth/bin/sidecar.mjs --port "${IDENTYCLAW_AUTH_PORT:-9910}"
# restart gateway so plugins load
```

HMAC `/webhooks/{route}` is unchanged. Signed ingress is `/hooks/wake` and
`/hooks/agent`. Plugin manifests install as `$HERMES_HOME/plugins/a2a-platform/`
and `$HERMES_HOME/plugins/identyclaw-webhooks/`.

NixOS users can declare the same GitHub sources via
[`extraPlugins`](https://hermes-agent.nousresearch.com/docs/getting-started/nix-setup)
instead of `hermes plugins install`.

### Optional: one-shot helper from this umbrella

If you prefer a single script (clones siblings next to this repo):

```bash
git clone https://github.com/discernible-io/hermes-agents.git
cd hermes-agents
./install.sh --fetch              # Tier 1
./install.sh --fetch --peer       # Tier 2 + config enablement
```

## Podman on this host

```bash
cd ~/hermes-agents
./hermes.sh init && ./hermes.sh setup
./hermes.sh identyclaw-peer-install   # optional peer stack
./hermes.sh start
```

Runtime state: `~/hermes-agents-app/` (`HERMES_APP_DIR`). See [`deploy/README.md`](deploy/README.md).

## What this repo does not do

- It does not vendor Hermes core or the IdentyClaw plugin source.
- Passport replaces federated peer API keys, not model-provider keys.
- NEAR private keys and JWTs never go in git, skills, or chat.
