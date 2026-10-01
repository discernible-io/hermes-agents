# IdentyClaw plugins (external repos)

Passport packages are public GitHub repos. Install them with the stock Hermes
Plugins CLI (preferred), or keep sibling checkouts next to `hermes-agents` for
the Podman wrapper / `--local` install path.

| Local dir / GitHub | Plugin id | Role |
|--------------------|-----------|------|
| [`hermes-identyclaw-auth`](https://github.com/discernible-io/hermes-identyclaw-auth) | `identyclaw-auth` | `idcp` / `hermes identyclaw` + auth sidecar + skill |
| [`hermes-identyclaw-a2a`](https://github.com/discernible-io/hermes-identyclaw-a2a) | `identyclaw-a2a` | Passport A2A overlay (disable bundled `platforms/a2a`) |
| [`hermes-identyclaw-webhook`](https://github.com/discernible-io/hermes-identyclaw-webhook) | `identyclaw-webhooks` | RODiT `/hooks/*` (local sibling may still be named `…-webhooks`) |

`deploy/idcp` → `../hermes-identyclaw-auth`. Override with
`IDENTYCLAW_AUTH_DIR`, `IDENTYCLAW_A2A_DIR`, `IDENTYCLAW_WEBHOOKS_DIR`.

## Existing Hermes agent (official CLI)

```bash
export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
hermes plugins install discernible-io/hermes-identyclaw-auth --enable
hermes identyclaw install-deps
# Mint Passport, then for Tier 2:
bash "$HERMES_HOME/plugins/identyclaw-auth/scripts/install-stock-hermes.sh" \
  --a2a-public-url "https://YOUR.PUBLIC.HOST"
```

Or via this umbrella:

```bash
./install.sh               # Tier 1 via hermes plugins install
./install.sh --peer        # Tier 2 (delegates to install-stock-hermes.sh)
./install.sh --local --peer --fetch   # sibling copy into $HERMES_HOME/plugins/
```

## Podman wrapper (this host)

```bash
./deploy/hermes.sh identyclaw-peer-install
./deploy/hermes.sh start
```

## Layout after install

| Path | Role |
|------|------|
| `$HERMES_HOME/secrets/near-credentials/` | NEAR key JSON (`install-deps` / `enroll`) |
| `$HERMES_HOME/secrets/identyclaw/` | Per-host JWT cache (never print to the model) |
| `$HERMES_HOME/plugins/identyclaw-auth/` | Auth plugin + Node sidecar |
| `$HERMES_HOME/plugins/identyclaw-a2a/` | Tier 2 only |
| `$HERMES_HOME/plugins/identyclaw-webhooks/` | Tier 2 only |

HMAC `/webhooks/{route}` is unchanged. Signed ingress is `/hooks/wake` and `/hooks/agent`.
