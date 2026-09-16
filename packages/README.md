# IdentyClaw packages for Hermes

Publishable components (stock Hermes users can copy these without the Podman wrapper):

| Package | Role |
|---------|------|
| [`hermes-identyclaw-auth`](hermes-identyclaw-auth/) | `idcp` CLI + localhost RODiT auth sidecar (`@rodit/rodit-auth-be`) |
| [`hermes-identyclaw-a2a`](hermes-identyclaw-a2a/) | Platform overlay (`a2a-platform`) — Passport JWT + `/api/login*` |
| [`hermes-identyclaw-webhooks`](hermes-identyclaw-webhooks/) | Platform — RODiT `/hooks/wake` + `/hooks/agent` + `send_rodit_webhook` |

**Operator path (this fork):** `./deploy/hermes.sh identyclaw-peer-install`

**Stock Hermes:** install auth with npm, copy the two platform dirs into `$HERMES_HOME/plugins/`, enable plugins, run the sidecar, point Passport `metadata.webhook_url` at your public HTTPS base.
