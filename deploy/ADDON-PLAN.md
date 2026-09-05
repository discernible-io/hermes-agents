# Hermes add-on plan (IdentyClaw Passport + generic CLI skills)

Stock Nous Hermes does **not** ship IdentyClaw Passport / RODiT. This repo already bolts it on as an optional host-side add-on. This plan records how we package that pattern for practitioners, what stays local, and what (if anything) to request upstream from Nous.

## Goals

1. Practitioners can add Passport to a stock `nousresearch/hermes-agent` install without forking the image.
2. The same packaging pattern works for other host CLI skills (e.g. Himalaya).
3. Upstream asks stay **generic** (extension hooks), not IdentyClaw-specific product surface.

## Non-goals

- Baking Passport / RODiT / `idcp` into the Nous image.
- OpenClaw plugin compatibility (Hermes is not OpenClaw).
- Changing IdentyClaw purchase / mint UX.

## Package shape (three layers)

| Layer | Role | Location |
|-------|------|----------|
| **CLI** | Enroll, JWT session, HOLA, API calls | Synced `idcp/` → mounted `/opt/idcp` |
| **Skill** | Agent instructions: call `idcp`, never invent crypto / paste JWTs | `skills/identyclaw/SKILL.md` → copied to `hermes-agents-app/skills/identity/identyclaw/` |
| **Secrets** | NEAR keys + JWT cache | `hermes-agents-app/secrets/` only (never in image or git) |

Code stays in the synced repo; runtime identity stays in the sibling app dir (`HERMES_APP_DIR`).

## Practitioner path (current)

```bash
./hermes.sh setup              # Hermes wizard + IdentyClaw (required on this fork)
# or Passport-only resume:
./hermes.sh idcp-setup         # install → enroll → purchase guide → ensure_session → me
./hermes.sh start              # remount /opt/idcp + secrets for gateway / sandboxes
```

Low-level (same steps `idcp-setup` runs):

```bash
./hermes.sh idcp-install
./hermes.sh idcp enroll
# Human: mint Passport at https://purchase.identyclaw.com with account_id
./hermes.sh idcp ensure_session
./hermes.sh idcp me
```

Optional docs MCP:

```bash
hermes mcp add IdentyClawDocs --url https://api.identyclaw.com/mcp
```

Same install style as Himalaya (`himalaya-install`): one command, then recreate gateway.

## Friction today (why wrappers exist)

These are the places stock Hermes forces local glue:

1. **`$HERMES_HOME/bin` not reliably on PATH** in gateway + docker terminal sandboxes → we write `bin/idcp` and inject `PATH`.
2. **Nested docker `-v` paths** — sandboxes need host-absolute sources, not `/opt/data` → dual-mount + `terminal.docker_volumes` rewriting in `ensure_sandbox_volumes`.
3. **Manual volume list** for `/opt/idcp`, secrets, and `bin` — `idcp-install` appends hints / patches `config.yaml`.
4. **Rootless Podman ownership** — gateway UID owns the app tree while running; host edits need `stop` / `own host` / `exec`.

## Packaging options (act later)

### A. Keep in this wrapper (default, now)

- Pros: already works; matches Himalaya; secrets stay out of the image.
- Cons: practitioners need this repo (or a copy of `idcp/` + skill + install script).

### B. Standalone release artifact

Ship a small tarball / npm package with:

- `idcp/` (CLI + vendored `hola-client`)
- `skills/identyclaw/SKILL.md`
- `install.sh` that:
  1. `npm install --omit=dev` in `idcp/`
  2. Copies skill into `$HERMES_HOME/skills/identity/identyclaw/`
  3. Writes `$HERMES_HOME/bin/idcp` shim
  4. Documents / merges `terminal.docker_volumes` for idcp + secrets + bin
  5. Prints enroll → purchase → `ensure_session` → recreate gateway

Target consumers: anyone on stock Hermes who does not want the full Podman wrapper.

### C. Upstream generic hooks (Nous) + keep Passport local

Best long-term combo: reduce friction in Hermes; keep IdentyClaw as an external add-on.

## Upstream ask to Nous (recommended)

**Frame:** first-class local CLI extensions for skills that shell out — **not** “please ship IdentyClaw.”

**Status:** opened upstream as [NousResearch/hermes-agent#83805](https://github.com/NousResearch/hermes-agent/pull/83805) (`feat: auto-mount $HERMES_HOME/bin for sidecar CLI skills`). Once merged and released in the image, most of our PATH / `docker_volumes` glue for `idcp` (and Himalaya) can shrink to skill + `bin/` install only.

### Request

1. Put `$HERMES_HOME/bin` on `PATH` in the gateway and docker terminal sandboxes by default.
2. Auto-mount convention for add-ons, e.g.:
   - `$HERMES_HOME/bin` → readable in sandbox
   - `$HERMES_HOME/secrets` → readable in sandbox (or a documented subset)
   - optional documented `extensions/` or tool mount list
3. Short docs page: **sidecar tool pattern** — skill under `skills/` + binary under `bin/` + secrets under `secrets/` + `docker_volumes` / env notes.
4. Rootless Podman / nested volume guidance (host path vs in-container `/opt/data`) so dual-mount is documented or unnecessary.

### Do not request

- IdentyClaw / Passport / RODiT in core
- OpenClaw plugin loader
- Purchase / enroll flows

### Example issue blurb

> Skills that shell out to host CLIs (mail, identity helpers, etc.) need `$HERMES_HOME/bin` on PATH and a documented default for mounting `bin` (+ optional `secrets`) into the docker terminal backend. Today each add-on hand-edits `terminal.docker_volumes` and injects PATH. A small convention would make third-party CLI skills installable without forking Hermes.

Mention IdentyClaw only as one consumer example.

## Comparison: this wrapper vs stock Nous Hermes

| Concern | Stock [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | This fork (`discernible-io/hermes-agents` + `deploy/`) |
|---------|----------------------------------------------------------------------------------|--------------------------------------------|
| Runtime image | `nousresearch/hermes-agent` (source in upstream) | Same image; **no fork** of Hermes |
| Host orchestration | `docker compose` / install.sh / desktop | Rootless **Podman** via `deploy/hermes.sh` + sibling `hermes-agents-app/` |
| IdentyClaw Passport | Not included | `idcp/` CLI + `skills/identyclaw/` + `idcp-install` |
| Himalaya / Migadu | Not included | `himalaya-install` + email skill |
| Webhook TLS ingress | Built-in webhook adapter; TLS is your problem | Optional nginx sidecar pod (`HERMES_DEPLOY_MODE=pod`) |
| Sandbox `bin/` PATH | Local terminal only (until #83805) | Wrapper injects PATH + `terminal.docker_volumes` today |
| Secrets | Under `HERMES_HOME` | Under `hermes-agents-app/secrets/` (never in synced repo) |

Practitioners who only want Passport on stock Hermes can copy `idcp/` + the skill and follow the upstream sidecar guide once #83805 lands; until then use `./hermes.sh idcp-install` in this wrapper.

## Local work backlog

- [x] Keep `idcp-install` / `idcp` as the supported Hermes path in this repo.
- [ ] Align Himalaya and IdentyClaw install UX (same prompts: skill path, bin shim, volumes, “recreate gateway”).
- [ ] Decide: extract standalone release (option B) vs wrapper-only (option A).
- [ ] If extracting: pin `idcp` version, include `SKILL.md`, smoke-test enroll + `ensure_session` + sandbox `idcp me`.
- [x] Draft / file Nous feature request (generic hooks above) → [PR #83805](https://github.com/NousResearch/hermes-agent/pull/83805).
- [ ] After #83805 merges: drop redundant PATH / `docker_volumes` patches where upstream covers `bin/`.
- [ ] Optional: one-page practitioner quickstart link from README → this plan’s “Practitioner path”.

## Security / ops constraints

- Never put JWTs or NEAR private keys in chat, skills, or the synced repo.
- `idcp ensure_session` / `list_sessions` must keep returning metadata only (no full JWT in agent-visible output).
- Secrets dirs stay `0700`; gateway recreate after install so mounts apply.
- Identity auth for webhooks remains Hermes HMAC in this stack — Passport is agent identity / HOLA, not ingress auth.

## Success criteria

- New machine: stock Hermes image + one install command + enroll/purchase/session → agent can `idcp me` / HOLA from terminal sandbox.
- No custom Hermes image required.
- Upstream (if accepted) removes most of our PATH / volume glue for **all** CLI add-ons, not only Passport.
