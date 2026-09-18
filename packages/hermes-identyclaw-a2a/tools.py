"""Outbound A2A tools: Passport JWT via sidecar login_server instead of auth.token."""

from __future__ import annotations

import urllib.error

from plugins.platforms.a2a import tools as bundled

from . import security as passport

_orig_send_task = bundled._send_task


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


def register_tools(ctx) -> None:
    """Register bundled A2A client tools with Passport outbound auth."""
    bundled._send_task = _send_task  # type: ignore[method-assign]
    bundled.register_tools(ctx)
