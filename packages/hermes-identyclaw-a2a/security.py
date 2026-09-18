"""Passport JWT auth for the identyclaw A2A overlay — sidecar validate_jwt / login_server.

Inbound identity is the peer's Passport token_id. Outbound obtains a per-peer JWT
via login_server against the peer base URL (no static bearer in a2a_agents).
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
import urllib.error
import urllib.request
from typing import Optional
from urllib.parse import urlparse, urlunparse

logger = logging.getLogger(__name__)

_DEFAULT_SIDECAR = "http://127.0.0.1:9910"
_DEFAULT_ISSUER = "https://api.identyclaw.com"
_JWT_CACHE_TTL = 300
_TIMEOUT = 30

_cache_lock = threading.Lock()
_jwt_cache: dict[str, tuple[str, float]] = {}


def sidecar_url() -> str:
    return (os.getenv("A2A_AUTH_SIDECAR_URL") or _DEFAULT_SIDECAR).rstrip("/")


def jwt_audience() -> str:
    return (os.getenv("IDENTYCLAW_JWT_AUDIENCE") or "").strip()


def jwt_issuer() -> str:
    return (os.getenv("IDENTYCLAW_JWT_ISSUER") or _DEFAULT_ISSUER).strip()


def passport_mode() -> bool:
    """True when the overlay should require Passport JWTs (sidecar + audience)."""
    explicit = (os.getenv("IDENTYCLAW_A2A_AUTH") or "").strip().lower()
    if explicit in {"passport-jwt", "passport", "rodit", "1", "true", "yes"}:
        return True
    if explicit in {"bearer", "off", "0", "false", "no"}:
        return False
    return bool(jwt_audience() or os.getenv("A2A_AUTH_SIDECAR_URL"))


def identyclaw_card_extensions() -> dict:
    """Agent Card extensions peers use to discover Passport auth (aud is authoritative)."""
    ext: dict = {
        "auth": "passport-jwt",
        "login": {
            "timestamp": "/api/login/timestamp",
            "login": "/api/login",
        },
    }
    aud = jwt_audience()
    if aud:
        ext["audience"] = aud
    iss = jwt_issuer()
    if iss:
        ext["issuer"] = iss
    return {"identyclaw": ext}


def login_base_url(url: str) -> str:
    """Peer Agent Card / RPC URL → origin used for P2P /api/login."""
    raw = (url or "").strip()
    if not raw:
        return ""
    parsed = urlparse(raw if "://" in raw else f"https://{raw}")
    path = (parsed.path or "").rstrip("/")
    for suffix in ("/a2a", "/.well-known/agent-card.json", "/.well-known/agent.json"):
        if path.endswith(suffix):
            path = path[: -len(suffix)]
            break
    return urlunparse((parsed.scheme or "https", parsed.netloc, path.rstrip("/"), "", "", "")).rstrip("/")


def _post_json(path: str, body: dict, timeout: int = _TIMEOUT) -> dict:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        sidecar_url() + path,
        data=data,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 — loopback sidecar
        return json.loads(resp.read().decode("utf-8"))


def validate_jwt(token: str) -> Optional[str]:
    """Return Passport token_id (or None) for a presented Bearer JWT."""
    presented = (token or "").strip()
    if not presented:
        return None
    try:
        result = _post_json("/validate_jwt", {
            "token": presented,
            "audience": jwt_audience(),
            "issuer": jwt_issuer(),
        })
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError, OSError) as exc:
        logger.warning("A2A Passport: validate_jwt failed: %s", exc)
        return None
    if not isinstance(result, dict) or not result.get("ok"):
        return None
    identity = str(result.get("token_id") or result.get("label") or "").strip()
    return identity or None


def login_server(peer_url: str) -> Optional[str]:
    """Obtain a Passport JWT for *peer_url* via sidecar login_server (cached per login base)."""
    base = login_base_url(peer_url)
    if not base:
        return None
    now = time.time()
    with _cache_lock:
        cached = _jwt_cache.get(base)
        if cached and now < cached[1]:
            return cached[0]
    try:
        result = _post_json("/login_server", {"apiEndpoint": base})
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError, OSError) as exc:
        logger.warning("A2A Passport: login_server failed for %s: %s", base, exc)
        return None
    if not isinstance(result, dict) or not result.get("ok"):
        logger.warning("A2A Passport: login_server rejected for %s", base)
        return None
    token = str(result.get("jwt") or result.get("jwt_token") or "").strip()
    if not token:
        return None
    ttl = int(result.get("ttl_seconds") or _JWT_CACHE_TTL)
    with _cache_lock:
        _jwt_cache[base] = (token, now + max(1, ttl))
    return token


def invalidate_login(peer_url: str = "") -> None:
    base = login_base_url(peer_url) if peer_url else ""
    with _cache_lock:
        if base:
            _jwt_cache.pop(base, None)
        else:
            _jwt_cache.clear()


def proxy_sidecar(method: str, path: str, body: bytes = b"", content_type: str = "") -> tuple[int, bytes, str]:
    """Forward a public login request to the sidecar. Returns (status, body, content_type)."""
    url = sidecar_url() + path
    headers = {"Accept": "application/json"}
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=body or None, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=_TIMEOUT) as resp:  # noqa: S310 — loopback sidecar
            ctype = resp.headers.get("Content-Type") or "application/json"
            return resp.status, resp.read(), ctype
    except urllib.error.HTTPError as exc:
        ctype = exc.headers.get("Content-Type") if exc.headers else "application/json"
        return exc.code, exc.read() or b'{"error":"login failed"}', ctype or "application/json"
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        logger.warning("A2A Passport: sidecar proxy %s %s failed: %s", method, path, exc)
        payload = json.dumps({"error": "auth sidecar unavailable"}).encode("utf-8")
        return 502, payload, "application/json"
