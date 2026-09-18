# IdentyClaw A2A overlay for Hermes

Install into `$HERMES_HOME/plugins/a2a-platform/` (same manifest key as bundled A2A).

Requires the auth sidecar (`@identyclaw/hermes-identyclaw-auth`) and:

```yaml
plugins:
  enabled:
    - a2a-platform
  entries:
    a2a-platform:
      enabled: true
      allow_tool_override: true   # or granted_capabilities: [tools.override]
```

Env: `NEAR_CREDENTIALS_FILE_PATH` (JWT `aud` from `RoditClient.getConfigOwnRodit()`),
`A2A_PUBLIC_URL`, `IDENTYCLAW_AUTH_PORT=9910`. `IDENTYCLAW_JWT_AUDIENCE` is optional fallback only.
