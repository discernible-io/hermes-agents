# Persona seeds (not shipped)

Tenant persona data (SOUL, MEMORY, catalog skills) belongs in the companion
**`-app`** directory, not in this git checkout:

```text
~/hermes-agents-app/seed/<name>/
```

`./hermes.sh start` and `./hermes.sh mundo-seed` sync
`~/hermes-agents-app/seed/mundo-en-blanco/` into the live `-app` paths.

Do not commit real shop catalogs, WhatsApp numbers, or operator notes here.
