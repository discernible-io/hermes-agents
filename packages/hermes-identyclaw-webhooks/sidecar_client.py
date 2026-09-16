"""Shared sidecar HTTP helpers (mirrors a2a package client)."""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from typing import Any, Optional


def sidecar_base() -> str:
    host = os.getenv("IDENTYCLAW_AUTH_HOST", "127.0.0.1").strip() or "127.0.0.1"
    port = os.getenv("IDENTYCLAW_AUTH_PORT", "9910").strip() or "9910"
    return f"http://{host}:{port}"


def _post(path: str, body: dict, timeout: float = 60.0) -> dict:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        sidecar_base().rstrip("/") + path,
        data=data,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            payload = json.loads(e.read().decode("utf-8"))
        except Exception:
            payload = {"ok": False, "error": str(e), "status": e.code}
        payload.setdefault("ok", False)
        return payload


def authenticate_webhook(
    payload: str,
    signature: str,
    timestamp: str,
    *,
    public_key: str = "",
    headers: Optional[dict] = None,
) -> dict[str, Any]:
    body: dict[str, Any] = {
        "payload": payload,
        "signature": signature,
        "timestamp": timestamp,
    }
    if public_key:
        body["publicKey"] = public_key
    if headers:
        body["headers"] = headers
    return _post("/v1/authenticate_webhook", body)


def send_webhook(
    peer_base_url: str,
    *,
    hook_path: str = "hooks/wake",
    text: str = "",
    session_rodit_id: str = "",
    data: Optional[dict] = None,
) -> dict[str, Any]:
    body: dict[str, Any] = {
        "peerBaseUrl": peer_base_url,
        "hookPath": hook_path,
        "text": text,
    }
    if session_rodit_id:
        body["sessionRoditId"] = session_rodit_id
    if data:
        body["data"] = data
    return _post("/v1/send_webhook", body, timeout=120.0)
