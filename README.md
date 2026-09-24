# IdentyClaw for Hermes

Umbrella repo: rootless Podman operator (`deploy/`) plus `install.sh` for an
existing [Hermes Agent](https://github.com/NousResearch/hermes-agent). Passport
plugins are public sibling repositories.

| Piece | Repo |
|---|---|
| [`install.sh`](install.sh) | Install into `$HERMES_HOME` |
| [`deploy/`](deploy/README.md) | Podman operator (`./hermes.sh`) |
| Auth / `idcp` | [discernible-io/hermes-identyclaw-auth](https://github.com/discernible-io/hermes-identyclaw-auth) |
| A2A plugin | [discernible-io/hermes-identyclaw-a2a](https://github.com/discernible-io/hermes-identyclaw-a2a) |
| Webhooks plugin | [discernible-io/hermes-identyclaw-webhook](https://github.com/discernible-io/hermes-identyclaw-webhook) |

## Existing Hermes agent

```bash
git clone https://github.com/discernible-io/hermes-agents.git
cd hermes-agents
./install.sh --fetch              # Tier 1: clone auth + install idcp/skill
./install.sh --fetch --peer       # Tier 2: also A2A + signed /hooks/*
```

Or install the Python plugins directly:

```bash
hermes plugins install discernible-io/hermes-identyclaw-a2a --enable
hermes plugins install discernible-io/hermes-identyclaw-webhook --enable
# grant tools.override for a2a-platform when prompted
```

`HERMES_HOME` defaults to `~/.hermes`. Put `$HERMES_HOME/bin` on PATH, then
`idcp enroll` → mint at [purchase.identyclaw.com](https://purchase.identyclaw.com)
→ `idcp ensure_session`. Tier 2 also needs the auth sidecar and a gateway restart.

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
