"""Outbound A2A tools: Passport JWT + IdentyClaw directory peer resolution.

Peers resolve in order:
1. Full http(s) URL
2. Optional static ``a2a_agents`` override
3. Passport ``tokenId`` via ``GET /api/identity/token/{id}/public`` → ``webhookUrl``

Outbound auth uses sidecar ``login_server`` (no static bearer).
"""

from __future__ import annotations

import urllib.error
from typing import Any, Optional

from plugins.platforms.a2a import tools as bundled

from . import directory
from . import security as passport

_orig_send_task = bundled._send_task
_orig_resolve_peer = bundled._resolve_peer
_orig_a2a_discover = bundled.a2a_discover
_orig_a2a_list = bundled.a2a_list


def _auth_header_for_peer(peer: dict) -> dict:
    auth = peer.get("auth") or {}
    if isinstance(auth, dict) and str(auth.get("type") or "").lower() == "bearer" and auth.get("token"):
        return {"Authorization": f"Bearer {auth['token']}"}
    kind = str(auth.get("type") or "").strip().lower()
    if kind in {"none", "disabled"}:
        return {}
    url = str(peer.get("url") or peer.get("loginBaseUrl") or "").strip()
    token = passport.login_server(url) if url else None
    return {"Authorization": f"Bearer {token}"} if token else {}


def _send_task(agent_label: str, peer: dict, message: str, context_id: str) -> tuple[str, str, str]:
    """Same as bundled send, with Passport login_server and one 401 retry."""
    headers = _auth_header_for_peer(peer)
    wrapped = dict(peer)
    wrapped["auth"] = {"type": "bearer", "token": headers.get("Authorization", "").split(None, 1)[-1]} if headers else {}
    try:
        return _orig_send_task(agent_label, wrapped, message, context_id)
    except urllib.error.HTTPError as exc:
        if exc.code != 401:
            raise
        passport.invalidate_login(str(peer.get("url") or ""))
        headers = _auth_header_for_peer(peer)
        wrapped["auth"] = {"type": "bearer", "token": headers.get("Authorization", "").split(None, 1)[-1]} if headers else {}
        return _orig_send_task(agent_label, wrapped, message, context_id)


def _resolve_peer(agent: str) -> Optional[dict]:
    """URL → config override → IdentyClaw public directory (tokenId)."""
    peer = _orig_resolve_peer(agent)
    if peer and peer.get("url"):
        return peer
    return directory.resolve_peer_by_token(agent)


def _a2a_call(args: dict, **kwargs: Any) -> str:
    agent = str(args.get("agent") or args.get("agent_name") or args.get("name") or "").strip()
    message = str(args.get("message") or args.get("text") or args.get("task") or "").strip()
    context_id = str(args.get("context_id") or args.get("contextId") or "").strip()
    if not agent or not message:
        return "Error: both 'agent' and 'message' are required."
    peer = _resolve_peer(agent)
    if not peer or not peer.get("url"):
        hint = (
            "Pass a Passport tokenId (resolved via api.identyclaw.com), "
            "a full http(s):// URL, or an optional a2a_agents override."
        )
        return f"Error: unknown agent '{agent}'. {hint}"
    label = peer.get("displayName") or peer.get("tokenId") or agent
    try:
        reply, reply_ctx, state = _send_task(str(label), peer, message, context_id)
    except urllib.error.HTTPError as e:
        return bundled._HTTP_CALL_ERRORS.get(
            e.code, "Error: call to '{agent}' failed — HTTP {code}."
        ).format(agent=agent, code=e.code)
    except ValueError as e:
        return str(e)
    except Exception as e:
        return f"Error: call to '{agent}' failed — {e}."
    short_state = state.replace("TASK_STATE_", "").replace("_", "-").lower()
    header = f"[{agent} · context {reply_ctx}" + (f" · {short_state}" if state else "") + "]"
    body = reply or "(no text reply)"
    if state == bundled.protocol.STATE_INPUT_REQUIRED:
        body += (
            f"\n\n(The peer needs more input — answer by calling a2a_call again "
            f"with context_id '{reply_ctx}'.)"
        )
    return f"{header}\n{body}"


def _a2a_discover(args: dict, **kwargs: Any) -> str:
    raw = str(args.get("url") or args.get("agent") or args.get("tokenId") or "").strip()
    if not raw:
        return "Error: 'url' is required (A2A base URL or Passport tokenId)."
    if raw.startswith(("http://", "https://")):
        return _orig_a2a_discover({"url": raw}, **kwargs)
    peer = directory.resolve_peer_by_token(raw)
    if not peer or not peer.get("url"):
        return (
            f"Error: could not resolve Passport '{raw}' via "
            f"{directory.api_base()}/api/identity/token/…/public."
        )
    card = _orig_a2a_discover({"url": peer["url"]}, **kwargs)
    meta = (
        f"IdentyClaw: {peer.get('displayName') or peer.get('tokenId')} "
        f"(tokenId={peer.get('tokenId')}, webhookUrl={peer.get('url')})"
    )
    if peer.get("ownerAccountId"):
        meta += f"\nPassport ownerAccountId (JWT aud): {peer['ownerAccountId']}"
    return f"{meta}\n{card}"


def _a2a_list(args: dict | None = None, **kwargs: Any) -> str:
    base = _orig_a2a_list(args, **kwargs)
    lines = [
        base,
        "",
        "Dynamic discovery (api.identyclaw.com):",
        "  - a2a_call agent=<12-letter tokenId>  # resolves webhookUrl via /public",
        "  - a2a_discover url=<tokenId>          # same, then fetches Agent Card",
        "  - idcp request GET /api/agents        # directory page (no JWT)",
        "Static a2a_agents entries are optional overrides only.",
    ]
    return "\n".join(lines)


def register_tools(ctx) -> None:
    """Register A2A client tools with Passport auth + directory resolution."""
    bundled._send_task = _send_task  # type: ignore[method-assign]
    bundled._resolve_peer = _resolve_peer  # type: ignore[method-assign]
    bundled.a2a_call = _a2a_call  # type: ignore[method-assign]
    bundled.a2a_discover = _a2a_discover  # type: ignore[method-assign]
    bundled.a2a_list = _a2a_list  # type: ignore[method-assign]

    call_desc = (
        "Send a natural-language task to a remote A2A agent. "
        "'agent' may be a Passport tokenId (resolved via api.identyclaw.com), "
        "a full http(s):// URL, or an optional a2a_agents name. "
        "Pass 'context_id' from a previous reply to continue a multi-turn exchange."
    )
    discover_desc = (
        "Fetch and summarize another agent's A2A Agent Card. "
        "'url' may be an http(s) base URL or a Passport tokenId "
        "(resolved via api.identyclaw.com → webhookUrl)."
    )
    bundled._TOOLS["a2a_call"] = (
        _a2a_call,
        call_desc,
        {
            "agent": bundled._str(
                "Passport tokenId (preferred), http(s) URL, or optional a2a_agents name."
            ),
            "message": bundled._str("The task / message to send the peer, in natural language."),
            "context_id": bundled._str(
                "Optional: context id from a prior reply, to continue the conversation."
            ),
        },
        ["agent", "message"],
    )
    bundled._TOOLS["a2a_discover"] = (
        _a2a_discover,
        discover_desc,
        {
            "url": bundled._str(
                "A2A base URL or Passport tokenId (e.g. bdshbmlhsdbh)."
            ),
        },
        ["url"],
    )
    bundled._TOOLS["a2a_list"] = (
        _a2a_list,
        "List optional static A2A peers, persisted conversations, metrics, and "
        "IdentyClaw directory discovery hints.",
        {},
        [],
    )
    bundled.register_tools(ctx)
