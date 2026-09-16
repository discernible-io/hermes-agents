"""Outbound A2A tools with Passport login_server via auth sidecar."""

from __future__ import annotations

import json
import logging
import time
import urllib.error
import urllib.request
from typing import Any, Optional

from plugins.platforms.a2a import protocol, security
from plugins.platforms.a2a.tools import (
    _DEFAULT_TIMEOUT,
    _TOOLS,
    _a2a_tools_available,
    _configured_peers,
    _fetch_card,
    _http_post_json,
    _match_peers_by_capability,
    _peer_from_entry,
    _reply_text_from_result,
    _resolve_peer,
    _rpc_url,
    a2a_discover,
    a2a_history,
    a2a_list,
)

logger = logging.getLogger(__name__)

# peer_url -> (jwt, expires_at_monotonic)
_peer_jwt_cache: dict[str, tuple[str, float]] = {}
_JWT_CACHE_TTL = 300.0


def _auth_header_passport(peer: dict) -> dict:
    """Static bearer from config, else login_server to peer base URL."""
    auth = peer.get("auth") or {}
    if auth.get("type") == "bearer" and auth.get("token"):
        return {"Authorization": f"Bearer {auth['token']}"}
    base = (peer.get("url") or "").rstrip("/")
    if not base:
        return {}
    now = time.monotonic()
    cached = _peer_jwt_cache.get(base)
    if cached and now < cached[1]:
        return {"Authorization": f"Bearer {cached[0]}"}
    try:
        from . import sidecar_client

        # Peer login endpoint is the peer's own /api/login (gateway base).
        result = sidecar_client.login_server(api_endpoint=base)
        token = result.get("jwt_token")
        if not token:
            raise RuntimeError(result.get("error") or "login_server returned no jwt_token")
        _peer_jwt_cache[base] = (token, now + _JWT_CACHE_TTL)
        return {"Authorization": f"Bearer {token}"}
    except Exception as e:
        logger.warning("IdentyClaw A2A: outbound login_server failed for %s: %s", base, e)
        return {}


def _send_task(agent_label: str, peer: dict, message: str, context_id: str) -> tuple[str, str, str]:
    base_url = peer.get("url", "")
    headers = _auth_header_passport(peer)
    timeout = int(peer.get("timeout", _DEFAULT_TIMEOUT))
    try:
        card = _fetch_card(base_url, headers, min(timeout, 30))
    except Exception:
        card = None
    ctx = context_id or protocol.new_context_id()
    safe_message = security.redact_outbound(message)
    rpc_body = {
        "jsonrpc": "2.0",
        "id": protocol.new_task_id(),
        "method": "SendMessage",
        "params": {
            "message": protocol.text_message(protocol.ROLE_USER, safe_message, context_id=ctx)
        },
    }
    from plugins.platforms.a2a.tools import _select_jsonrpc_interface

    iface = _select_jsonrpc_interface(card)
    tenant = str(iface["tenant"]) if iface and iface.get("tenant") else str(peer.get("tenant") or "")
    if tenant:
        rpc_body["params"]["tenant"] = tenant
    security.audit("outbound", agent_label, rpc_body["id"], safe_message)
    protocol.persist_message(ctx, "user", safe_message, rpc_body["id"])
    protocol.metrics.outbound_total += 1
    resp = _http_post_json(_rpc_url(base_url, card), rpc_body, headers, timeout)
    if "error" in resp:
        raise ValueError(
            f"Peer '{agent_label}' returned an error: {resp['error'].get('message', resp['error'])}"
        )
    payload = protocol.unwrap_send_message_response(resp.get("result", {}))
    reply = _reply_text_from_result(payload)
    reply_ctx, state = ctx, ""
    if isinstance(payload, dict):
        reply_ctx = payload.get("contextId", ctx)
        state = (payload.get("status") or {}).get("state", "")
    protocol.persist_message(reply_ctx, "agent", reply, rpc_body["id"])
    protocol.metrics.inbound_total += 1
    return reply, reply_ctx, state


_AUTH_ERR = "Error: peer '{agent}' rejected auth (HTTP {code}). Check Passport login / sidecar."
_HTTP_CALL_ERRORS = {
    401: _AUTH_ERR,
    403: _AUTH_ERR,
    429: "Error: peer '{agent}' rate limited us (HTTP 429). Retry later.",
}


def a2a_call(args: dict, **_: Any) -> str:
    agent = str(args.get("agent") or args.get("agent_name") or args.get("name") or "").strip()
    message = str(args.get("message") or args.get("text") or args.get("task") or "").strip()
    context_id = str(args.get("context_id") or args.get("contextId") or "").strip()
    if not agent or not message:
        return "Error: both 'agent' and 'message' are required."
    peer = _resolve_peer(agent)
    if not peer or not peer.get("url"):
        return (
            f"Error: unknown agent '{agent}'. Configure it under 'a2a_agents' in config.yaml "
            "or pass a full http(s):// URL."
        )
    try:
        reply, reply_ctx, state = _send_task(agent, peer, message, context_id)
    except urllib.error.HTTPError as e:
        # Invalidate cache on 401 so next call re-logins.
        base = (peer.get("url") or "").rstrip("/")
        _peer_jwt_cache.pop(base, None)
        return _HTTP_CALL_ERRORS.get(e.code, "Error: call to '{agent}' failed — HTTP {code}.").format(
            agent=agent, code=e.code
        )
    except ValueError as e:
        return str(e)
    except Exception as e:
        return f"Error: call to '{agent}' failed — {e}."
    short_state = state.replace("TASK_STATE_", "").replace("_", "-").lower()
    header = f"[{agent} · context {reply_ctx}" + (f" · {short_state}" if state else "") + "]"
    body = reply or "(no text reply)"
    if state == protocol.STATE_INPUT_REQUIRED:
        body += (
            f"\n\n(The peer needs more input — answer by calling a2a_call again "
            f"with context_id '{reply_ctx}'.)"
        )
    return f"{header}\n{body}"


def a2a_orchestrate(args: dict, **_: Any) -> str:
    from concurrent.futures import ThreadPoolExecutor, as_completed
    from plugins.platforms.a2a.tools import _ORCHESTRATE_MAX_WORKERS, _call_peer_sync

    # Patch _call_peer_sync path by inlining with our _send_task
    capability = str(args.get("capability") or "").strip()
    message = str(args.get("message") or args.get("task") or "").strip()
    mode = str(args.get("mode") or "all").strip().lower()
    mode = mode if mode in ("all", "first", "best") else "all"
    context_id = str(args.get("context_id") or "").strip()
    if not message:
        return "Error: 'message' is required."
    if not capability:
        return "Error: 'capability' is required (or use '*' for all peers)."
    if not (matches := _match_peers_by_capability(capability)):
        return f"Error: no configured peers advertise capability '{capability}'."

    def _one(name: str, entry: dict) -> tuple[str, str]:
        peer = _peer_from_entry(entry, capabilities=entry.get("capabilities", []) or [])
        try:
            reply, _, _ = _send_task(name, peer, message, context_id)
            return name, reply or "(no reply)"
        except Exception as e:
            return name, f"Error: {e}"

    results: list[tuple[str, str]] = []
    with ThreadPoolExecutor(max_workers=min(len(matches), _ORCHESTRATE_MAX_WORKERS)) as pool:
        futures = {pool.submit(_one, name, entry): name for name, entry in matches}
        for fut in as_completed(futures):
            try:
                results.append(fut.result())
                if mode == "first" and not results[-1][1].startswith("Error:"):
                    for f in futures:
                        f.cancel()
                    break
            except Exception as e:
                results.append((futures[fut], f"Error: {e}"))
    results.sort(key=lambda r: r[0])
    successes = [(n, r) for n, r in results if not r.startswith("Error:")]
    if mode in ("best", "first"):
        if not successes:
            return "\n".join(["All peers failed:"] + [f"  {n}: {r}" for n, r in results])
        name, reply = max(successes, key=lambda r: len(r[1])) if mode == "best" else successes[0]
        return f"[{mode}: {name}]\n{reply}"
    return "\n".join(
        [f"Orchestrated '{capability}' to {len(matches)} peer(s):"]
        + [line for name, reply in results for line in (f"\n--- {name} ---", reply)]
    )


_OVERRIDE_TOOLS = {
    "a2a_discover": a2a_discover,
    "a2a_call": a2a_call,
    "a2a_list": a2a_list,
    "a2a_history": a2a_history,
    "a2a_orchestrate": a2a_orchestrate,
}


def register_tools(ctx) -> None:
    for name, (handler, description, properties, required) in _TOOLS.items():
        override_handler = _OVERRIDE_TOOLS.get(name, handler)
        ctx.register_tool(
            name=name,
            toolset="a2a",
            handler=override_handler,
            description=description,
            schema={
                "type": "object",
                "properties": properties,
                "required": required,
            },
            check_fn=_a2a_tools_available,
            override=True,
        )
