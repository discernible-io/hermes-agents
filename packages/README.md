# IdentyClaw plugins (external repos)

Passport packages are public GitHub repos. Locally they are usually sibling
checkouts next to `hermes-agents`:

| Local dir / GitHub | Role |
|--------------------|------|
| [`hermes-identyclaw-auth`](https://github.com/discernible-io/hermes-identyclaw-auth) | `idcp` CLI + auth sidecar + skill |
| [`hermes-identyclaw-a2a`](https://github.com/discernible-io/hermes-identyclaw-a2a) | Platform plugin `a2a-platform` |
| [`hermes-identyclaw-webhook`](https://github.com/discernible-io/hermes-identyclaw-webhook) | Platform plugin `identyclaw-webhooks` (local sibling may still be named `…-webhooks`) |

`deploy/idcp` → `../hermes-identyclaw-auth`. Override with
`IDENTYCLAW_AUTH_DIR`, `IDENTYCLAW_A2A_DIR`, `IDENTYCLAW_WEBHOOKS_DIR`.

## Existing Hermes agent

```bash
export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
./install.sh --fetch          # Tier 1
./install.sh --fetch --peer   # Tier 2
```

Or:

```bash
hermes plugins install discernible-io/hermes-identyclaw-a2a --enable
hermes plugins install discernible-io/hermes-identyclaw-webhook --enable
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
| `$HERMES_HOME/plugins/identyclaw-webhooks/` | Tier 2 only (manifest name) |

HMAC `/webhooks/{route}` is unchanged. Signed ingress is `/hooks/wake` and `/hooks/agent`.
