# IdentyClaw for Hermes

Umbrella repo: rootless Podman operator (`deploy/`) plus `install.sh` for an
existing [Hermes Agent](https://github.com/NousResearch/hermes-agent). Passport
plugins live in **sibling** repositories — not in this tree.

| Piece | Location |
|---|---|
| [`install.sh`](install.sh) | Install into `$HERMES_HOME` |
| [`deploy/`](deploy/README.md) | Podman operator (`./hermes.sh`) |
| Auth / `idcp` | [`../hermes-identyclaw-auth`](../hermes-identyclaw-auth/) |
| A2A plugin | [`../hermes-identyclaw-a2a`](../hermes-identyclaw-a2a/) |
| Webhooks plugin | [`../hermes-identyclaw-webhooks`](../hermes-identyclaw-webhooks/) |

## Existing Hermes agent

```bash
# siblings next to this repo (or: ./install.sh --fetch … once GitHub repos exist)
git clone https://github.com/discernible-io/hermes-agents.git
# + hermes-identyclaw-auth / -a2a / -webhooks as siblings

cd hermes-agents
./install.sh              # Tier 1: idcp + skill
./install.sh --peer       # Tier 2: + a2a-platform + signed /hooks/*
```

`HERMES_HOME` defaults to `~/.hermes`. Then put `$HERMES_HOME/bin` on PATH, run
`idcp enroll` → mint at [purchase.identyclaw.com](https://purchase.identyclaw.com)
→ `idcp ensure_session`. Tier 2 also needs the auth sidecar and a gateway restart.

Plugins alone (after the sibling repos are on GitHub):

```bash
hermes plugins install discernible-io/hermes-identyclaw-a2a
hermes plugins install discernible-io/hermes-identyclaw-webhooks
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
