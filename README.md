# IdentyClaw for Hermes

Plugins and a rootless Podman wrapper that add [IdentyClaw Passport](https://purchase.identyclaw.com) to **stock** [Nous Research Hermes Agent](https://github.com/NousResearch/hermes-agent).

This repository is not a Hermes fork. The agent runtime is the published image `docker.io/nousresearch/hermes-agent`. IdentyClaw stays outside core: a Node auth sidecar, two Hermes platform plugins, and an agent skill.

| Piece | Role |
|---|---|
| [`packages/hermes-identyclaw-auth`](packages/hermes-identyclaw-auth/) | `idcp` CLI and localhost RODiT auth sidecar |
| [`packages/hermes-identyclaw-a2a`](packages/hermes-identyclaw-a2a/) | Platform plugin `a2a-platform` — Passport JWT over bundled A2A |
| [`packages/hermes-identyclaw-webhooks`](packages/hermes-identyclaw-webhooks/) | Platform plugin `identyclaw-webhooks` — RODiT `/hooks/*` |
| [`deploy/`](deploy/README.md) | Optional Podman operator (`./hermes.sh`) |

Mint a Passport once at IdentyClaw home. Peers that implement the login contract (for example [api.lastcradle.io](https://api.lastcradle.io)) then issue their own JWT after a key-possession proof. No vendor API key. A home JWT is not accepted at a peer.

## Vanilla Hermes

Install [Hermes](https://hermes-agent.nousresearch.com/) the usual way, then follow [`packages/README.md`](packages/README.md).

Tier 1 (call federated peers) is the auth package plus the skill. Tier 2 (be a peer) installs the two plugins:

```bash
hermes plugins install discernible-io/hermes-agents/packages/hermes-identyclaw-a2a
hermes plugins install discernible-io/hermes-agents/packages/hermes-identyclaw-webhooks
```

Enable them in `$HERMES_HOME/config.yaml`. `a2a-platform` replaces bundled A2A tools, so it needs `tools.override` (`allow_tool_override: true` on older Hermes):

```yaml
plugins:
  enabled:
    - a2a-platform
    - identyclaw-webhooks
  entries:
    a2a-platform:
      enabled: true
      allow_tool_override: true
      granted_capabilities:
        - tools.override
    identyclaw-webhooks:
      enabled: true
```

HMAC `/webhooks/{route}` is unchanged. Signed ingress is `/hooks/wake` and `/hooks/agent`.

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
