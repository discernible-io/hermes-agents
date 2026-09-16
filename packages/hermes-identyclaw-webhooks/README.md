# IdentyClaw signed webhooks for Hermes

Install into `$HERMES_HOME/plugins/identyclaw-webhooks/`.

Serves `/hooks/wake` and `/hooks/agent` on `IDENTYCLAW_HOOKS_PORT` (default 9911).
Verification goes through the auth sidecar (`authenticate_webhook`).

Leaves Hermes HMAC `/webhooks/{route}` unchanged.
