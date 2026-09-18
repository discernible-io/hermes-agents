"""HTTP client for the IdentyClaw auth sidecar (localhost only)."""

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
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 — localhost sidecar
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            payload = json.loads(e.read().decode("utf-8"))
        except Exception:
            payload = {"ok": False, "error": str(e), "status": e.code}
        payload.setdefault("ok", False)
        payload["_http_status"] = e.code
        return payload


def _get(path: str, timeout: float = 10.0) -> dict:
    req = urllib.request.Request(
        sidecar_base().rstrip("/") + path,
        headers={"Accept": "application/json"},
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
        return json.loads(resp.read().decode("utf-8"))


def health() -> bool:
    try:
        return bool(_get("/health").get("ok"))
    except Exception:
        return False


def own_passport() -> dict[str, Any]:
    """Passport fields from RoditClient.getConfigOwnRodit() via the sidecar."""
    return _get("/v1/own_passport", timeout=30.0)


def validate_jwt(
    token: str,
    *,
    audience: Optional[str] = None,
    issuer: Optional[str] = None,
) -> dict[str, Any]:
    """Validate a peer JWT. Audience/issuer default to own passport on the sidecar."""
    body: dict[str, Any] = {"token": token}
    if audience:
        body["audience"] = audience
    if issuer:
        body["issuer"] = issuer
    return _post("/v1/validate_jwt", body)


def login_server(api_endpoint: Optional[str] = None) -> dict[str, Any]:
    body: dict[str, Any] = {}
    if api_endpoint:
        body["apiEndpoint"] = api_endpoint
    return _post("/v1/login_server", body, timeout=120.0)


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


def proxy_login_timestamp() -> dict[str, Any]:
    return _get("/api/login/timestamp")


def proxy_login(body: dict) -> tuple[int, dict]:
    """POST /api/login on the sidecar; returns (http_status, payload)."""
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        sidecar_base().rstrip("/") + "/api/login",
        data=data,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120.0) as resp:  # noqa: S310
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            payload = json.loads(e.read().decode("utf-8"))
        except Exception:
            payload = {"error": str(e)}
        return e.code, payload
