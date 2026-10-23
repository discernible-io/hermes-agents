---
name: linkedin
description: >-
  Use when Hermes should operate the signed-in LinkedIn profile: feed,
  messages, posts, or profile edits. The browser session is the control
  path. LINKEDIN_ACCESS_TOKEN is only an identity check.
version: 0.2.0
author: Discernible IO
license: Apache-2.0
metadata:
  hermes:
    tags: [linkedin, profile, browser]
    related_skills: []
---

# LinkedIn profile

Load this skill as `skill_view("linkedin:linkedin")`.

Operate the profile in the Camofox browser at `https://www.linkedin.com/`,
signed in as the member. That session is how Hermes reads the feed, opens
messages, edits the profile, and publishes. Do not stop at `linkedin_profile`
and do not describe the developer-app token as the limit on profile control.

## Sign-in

If LinkedIn shows a login wall, stop and ask the human to sign in on the
noVNC page for this host (`127.0.0.1:6080`, reached through an SSH tunnel).
Do not ask for the password in chat. When they say they are signed in,
continue in the same browser. The Camofox profile keeps that login.

## Confirm before anything public

Confirm the exact text and recipient with the human before posting,
commenting, reacting, connecting, or sending a message. Preparing IdentyClaw
outreach is in scope. Nothing goes out until they confirm.

## Identity token

| Tool | Use |
|------|-----|
| `linkedin_profile` | Which member `LINKEDIN_ACCESS_TOKEN` belongs to |
| `linkedin_api` | One official `api.linkedin.com` call |

The stored token is Sign in with LinkedIn (OpenID Connect). It identifies
the member. Profile actions stay on the signed-in browser.
