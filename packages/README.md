# IdentyClaw plugins (external repos)

The Passport packages no longer live in this tree. They are sibling checkouts
(or separate GitHub repos) next to `hermes-agents`:

| Directory / repo | Role |
|------------------|------|
| [`../hermes-identyclaw-auth`](../../hermes-identyclaw-auth/) ([GitHub](https://github.com/discernible-io/hermes-identyclaw-auth)) | `idcp` CLI + auth sidecar + skill |
| [`../hermes-identyclaw-a2a`](../../hermes-identyclaw-a2a/) ([GitHub](https://github.com/discernible-io/hermes-identyclaw-a2a)) | Platform plugin `a2a-platform` |
| [`../hermes-identyclaw-webhooks`](../../hermes-identyclaw-webhooks/) ([GitHub](https://github.com/discernible-io/hermes-identyclaw-webhooks)) | Platform plugin `identyclaw-webhooks` |

`deploy/idcp` is a symlink to `../hermes-identyclaw-auth`. Override paths with
`IDENTYCLAW_AUTH_DIR`, `IDENTYCLAW_A2A_DIR`, `IDENTYCLAW_WEBHOOKS_DIR`.

## Existing Hermes agent

From the `hermes-agents` umbrella (with siblings present, or `--fetch` once the
GitHub repos exist):

```bash
export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
./install.sh          # Tier 1: idcp + skill
./install.sh --peer   # Tier 2: + plugins + config enablement
# ./install.sh --fetch --peer   # clone missing siblings from GitHub
```

Or install plugins only via Hermes:

```bash
hermes plugins install discernible-io/hermes-identyclaw-a2a
hermes plugins install discernible-io/hermes-identyclaw-webhooks
```

## Podman wrapper (this host)

```bash
./deploy/hermes.sh identyclaw-peer-install
./deploy/hermes.sh start
```

## Layout after install

| Path | Role |
|------|------|
| `$HERMES_HOME/secrets/near-credentials/` | NEAR key JSON (`idcp enroll`) |
| `$HERMES_HOME/secrets/identyclaw/` | Per-host JWT cache (never print to the model) |
| `$HERMES_HOME/bin/idcp` | CLI shim on PATH |
| `$HERMES_HOME/skills/identity/identyclaw/` | Agent skill |
| `$HERMES_HOME/plugins/a2a-platform/` | Tier 2 only |
| `$HERMES_HOME/plugins/identyclaw-webhooks/` | Tier 2 only |

HMAC `/webhooks/{route}` is unchanged. Signed ingress is `/hooks/wake` and `/hooks/agent`.
