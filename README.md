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

Install the IdentyClaw auth plugin (official Hermes plugin installer):

```bash
hermes plugins install discernible-io/hermes-identyclaw-auth --enable
hermes identyclaw install-deps
# Mint Passport at https://purchase.identyclaw.com (recipient = printed account_id)
hermes identyclaw ensure_session
hermes identyclaw me
```

`install-deps` installs Node deps and creates a NEAR implicit account when none is
present (prints `account_id`). Re-run `hermes identyclaw enroll` only to reprint the id.

Optional docs MCP: `hermes mcp add IdentyClawDocs --url https://api.identyclaw.com/mcp`

### Tier 2 — Be a Passport peer (A2A + signed /hooks/*)

Requires Tier 1 with the auth sidecar healthy on `:9910`, then install the platform
plugins ([Plugins guide](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins)):

```bash
hermes identyclaw sidecar start
hermes plugins install discernible-io/hermes-identyclaw-a2a --enable
hermes plugins disable platforms/a2a                          # if bundled A2A still enabled
hermes plugins install discernible-io/hermes-identyclaw-webhook --enable
```

`identyclaw-a2a` replaces bundled A2A tools — grant `tools.override` when Hermes
prompts (or set `plugins.entries.identyclaw-a2a.allow_tool_override: true` /
`granted_capabilities: [tools.override]` in `$HERMES_HOME/config.yaml`).

Verify and manage with the same Nous CLI:

```bash
hermes plugins list
hermes plugins capabilities identyclaw-a2a
hermes identyclaw sidecar status
```

HMAC `/webhooks/{route}` is unchanged. Signed ingress is `/hooks/wake` and
`/hooks/agent`. Plugin manifests install as `$HERMES_HOME/plugins/identyclaw-auth/`,
`$HERMES_HOME/plugins/identyclaw-a2a/`, and `$HERMES_HOME/plugins/identyclaw-webhooks/`.

NixOS users can declare the same GitHub sources via
[`extraPlugins`](https://hermes-agent.nousresearch.com/docs/getting-started/nix-setup)
instead of `hermes plugins install`.

### Optional: one-shot helper from this umbrella

If you prefer a single script (clones siblings next to this repo):

```bash
git clone https://github.com/discernible-io/hermes-agents.git
cd hermes-agents
./install.sh                      # Tier 1 via hermes plugins install
./install.sh --peer               # Tier 2 (auth playbook / peer plugins)
./install.sh --local --fetch --peer   # sibling clone + copy (no hermes CLI)
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

<!-- discernible-io:product-links -->
## Links

Maintained by [Discernible](https://www.discernible.io/).

- **Product:** [discernible.io](https://www.discernible.io/)
- **Get a Passport:** [purchase.identyclaw.com](https://purchase.identyclaw.com) (buy once — no subscription)
- **Verify HOLA:** [verify.identyclaw.com](https://verify.identyclaw.com)
<!-- /discernible-io:product-links -->
