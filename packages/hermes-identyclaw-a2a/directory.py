"""Resolve A2A peers from api.identyclaw.com (tokenId → webhookUrl).

Static ``a2a_agents`` stays an optional override/cache. Prefer Passport
``tokenId`` + public profile lookup so hostnames can move without config edits.
"""

from __future__ import annotations

import json
import logging
import os
import re
import threading
import time
import urllib.error
import urllib.request
from typing import Any, Optional

logger = logging.getLogger(__name__)

_DEFAULT_API = "https://api.identyclaw.com"
_TIMEOUT = 20
_CACHE_TTL = 300

# 12-letter Passport tokenId (IdentyClaw face/creature encoding).
_TOKEN_ID_RE = re.compile(r"^[a-z]{12}$")
# Long form: bc=…;sc=…;id=<tokenId>
_LONG_TOKEN_RE = re.compile(r"(?:^|[;,&])id=([a-z]{12})(?:$|[;,&])", re.I)

_cache_lock = threading.Lock()
_profile_cache: dict[str, tuple[float, dict]] = {}


def api_base() -> str:
    return (os.getenv("IDENTYCLAW_BASE_URL") or _DEFAULT_API).rstrip("/")


def normalize_token_id(raw: str) -> str:
    """Return a 12-letter tokenId, or '' if *raw* is not a Passport id."""
    text = (raw or "").strip()
    if not text:
        return ""
    if _TOKEN_ID_RE.match(text):
        return text
    # did:rodit:<id>
    if text.lower().startswith("did:rodit:"):
        text = text.split(":", 2)[-1].strip()
        if _TOKEN_ID_RE.match(text):
            return text
    m = _LONG_TOKEN_RE.search(text.replace(" ", ""))
    if m:
        return m.group(1).lower()
    return ""


def _get_json(url: str, timeout: int = _TIMEOUT) -> dict:
    req = urllib.request.Request(url, headers={"Accept": "application/json"}, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 — public IdentyClaw API
        return json.loads(resp.read().decode("utf-8"))


def fetch_public_profile(token_id: str, *, force: bool = False) -> Optional[dict]:
    """GET /api/identity/token/{tokenId}/public (cached)."""
    tid = normalize_token_id(token_id)
    if not tid:
        return None
    now = time.time()
    with _cache_lock:
        cached = _profile_cache.get(tid)
        if cached and not force and now < cached[0]:
            return cached[1]
    url = f"{api_base()}/api/identity/token/{tid}/public"
    try:
        data = _get_json(url)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError, OSError) as exc:
        logger.warning("IdentyClaw directory: public profile failed for %s: %s", tid, exc)
        return None
    if not isinstance(data, dict) or not data.get("tokenId"):
        return None
    with _cache_lock:
        _profile_cache[tid] = (now + _CACHE_TTL, data)
    return data


def list_agents(*, limit: int = 25, cursor: str = "") -> dict[str, Any]:
    """GET /api/agents (public directory page)."""
    from urllib.parse import quote

    lim = max(1, min(int(limit or 25), 100))
    qs = f"limit={lim}"
    if cursor:
        qs += f"&cursor={quote(cursor, safe='')}"
    url = f"{api_base()}/api/agents?{qs}"
    try:
        data = _get_json(url)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError, OSError) as exc:
        logger.warning("IdentyClaw directory: /api/agents failed: %s", exc)
        return {"agents": [], "error": str(exc)}
    return data if isinstance(data, dict) else {"agents": []}


def peer_from_profile(profile: dict, *, timeout: int = 120) -> Optional[dict]:
    """Map a public Passport profile to an A2A peer dict."""
    if not isinstance(profile, dict):
        return None
    url = str(profile.get("webhookUrl") or profile.get("webhook_url") or "").strip()
    if not url:
        return None
    tid = normalize_token_id(str(profile.get("tokenId") or ""))
    caps: list[str] = []
    creature = str(profile.get("creature") or "").strip()
    if creature:
        caps.append(creature.lower())
    return {
        "url": url.rstrip("/"),
        "auth": {},
        "timeout": timeout,
        "capabilities": caps,
        "tokenId": tid or str(profile.get("tokenId") or ""),
        "displayName": str(profile.get("displayName") or ""),
        "ownerAccountId": str(profile.get("ownerAccountId") or ""),
        "source": "identyclaw-directory",
    }


def resolve_peer_by_token(agent: str, *, timeout: int = 120) -> Optional[dict]:
    """Resolve a Passport tokenId (or long-form id=) to an A2A peer via /public."""
    tid = normalize_token_id(agent)
    if not tid:
        return None
    profile = fetch_public_profile(tid)
    if not profile:
        return None
    return peer_from_profile(profile, timeout=timeout)


def invalidate(token_id: str = "") -> None:
    tid = normalize_token_id(token_id) if token_id else ""
    with _cache_lock:
        if tid:
            _profile_cache.pop(tid, None)
        else:
            _profile_cache.clear()
