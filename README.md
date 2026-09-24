# IdentyClaw for Hermes

Plugins and a rootless Podman wrapper that add [IdentyClaw Passport](https://purchase.identyclaw.com) to **stock** [Nous Research Hermes Agent](https://github.com/NousResearch/hermes-agent).

This repository is not a Hermes fork. The agent runtime is the published image `docker.io/nousresearch/hermes-agent`. IdentyClaw stays outside core: a Node auth sidecar, two Hermes platform plugins, and an agent skill.

| Piece | Role |
|---|---|
| [`install.sh`](install.sh) | One-shot installer into `$HERMES_HOME` for an existing Hermes agent |
| [`packages/hermes-identyclaw-auth`](packages/hermes-identyclaw-auth/) | `idcp` CLI and localhost RODiT auth sidecar |
| [`packages/hermes-identyclaw-a2a`](packages/hermes-identyclaw-a2a/) | Platform plugin `a2a-platform` — Passport JWT over bundled A2A |
| [`packages/hermes-identyclaw-webhooks`](packages/hermes-identyclaw-webhooks/) | Platform plugin `identyclaw-webhooks` — RODiT `/hooks/*` |
| [`deploy/`](deploy/README.md) | Optional Podman operator (`./hermes.sh`) |

Mint a Passport once at IdentyClaw home. Peers that implement the login contract (for example [api.lastcradle.io](https://api.lastcradle.io)) then issue their own JWT after a key-possession proof. No vendor API key. A home JWT is not accepted at a peer.

## Existing Hermes agent

```bash
git clone https://github.com/discernible-io/hermes-agents.git
cd hermes-agents
./install.sh              # Tier 1: idcp + skill
./install.sh --peer       # Tier 2: also A2A overlay + signed /hooks/*
```

`HERMES_HOME` defaults to `~/.hermes`. Override with `HERMES_HOME=/path ./install.sh --peer`.

Then put `$HERMES_HOME/bin` on PATH, run `idcp enroll` → mint at [purchase.identyclaw.com](https://purchase.identyclaw.com) → `idcp ensure_session`. For Tier 2, start the auth sidecar and restart the Hermes gateway. Details: [`packages/README.md`](packages/README.md).

You can also install only the Python plugins via Hermes:

```bash
hermes plugins install discernible-io/hermes-agents/packages/hermes-identyclaw-a2a
hermes plugins install discernible-io/hermes-agents/packages/hermes-identyclaw-webhooks
```

`a2a-platform` replaces bundled A2A tools, so it needs `tools.override` (`allow_tool_override: true` on older Hermes). HMAC `/webhooks/{route}` is unchanged; signed ingress is `/hooks/wake` and `/hooks/agent`.

## Podman on this host

```bash
git clone https://github.com/discernible-io/hermes-agents.git ~/hermes-agents
cd ~/hermes-agents
chmod +x hermes.sh deploy/hermes.sh
./hermes.sh init
./hermes.sh setup
./hermes.sh identyclaw-peer-install   # optional peer stack
./hermes.sh start
```

Runtime state lives in `~/hermes-agents-app/` (`HERMES_APP_DIR`). Operator reference: [`deploy/README.md`](deploy/README.md).

## What this repo does not do

- It does not vendor or patch Hermes core. Container recreate pulls `nousresearch/hermes-agent`.
- It does not replace model-provider API keys. Passport replaces service API keys on federated peers only.
- It does not put NEAR private keys or JWTs in git, skills, or chat.
