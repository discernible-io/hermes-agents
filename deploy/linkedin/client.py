"""LinkedIn API client. The access token stays in the process environment."""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

API_ORIGIN = "https://api.linkedin.com"
ALLOWED_METHODS = {"GET", "POST", "PUT", "PATCH", "DELETE"}
MAX_BODY_CHARS = 20000
TIMEOUT_SECONDS = 30


def _token() -> str:
    return os.environ.get("LINKEDIN_ACCESS_TOKEN", "").strip()


def redact(text: str, token: str | None = None) -> str:
    secret = token if token is not None else _token()
    if secret and secret in text:
        return text.replace(secret, "[redacted]")
    return text


def _error(message: str, **extra: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {"ok": False, "error": message}
    payload.update(extra)
    return payload


def normalize_path(path: str) -> str | None:
    raw = (path or "").strip()
    if not raw.startswith("/") or raw.startswith("//"):
        return None
    if "\\" in raw or ".." in raw.split("/"):
        return None
    parsed = urllib.parse.urlsplit(raw)
    if parsed.scheme or parsed.netloc:
        return None
    return urllib.parse.urlunsplit(("", "", parsed.path, parsed.query, ""))


def linkedin_request(
    method: str,
    path: str,
    *,
    body: Any = None,
    version: str | None = None,
) -> dict[str, Any]:
    """Call one api.linkedin.com path. Never includes the bearer token in the result."""
    token = _token()
    if not token:
        return _error("LINKEDIN_ACCESS_TOKEN is not set")

    verb = (method or "").strip().upper()
    if verb not in ALLOWED_METHODS:
        return _error("method must be GET, POST, PUT, PATCH, or DELETE", method=method)

    target = normalize_path(path)
    if target is None:
        return _error("path must be a relative api.linkedin.com path such as /v2/userinfo", path=path)

    url = API_ORIGIN + target
    headers = {
        "Authorization": "Bearer " + token,
        "Accept": "application/json",
        "X-Restli-Protocol-Version": "2.0.0",
    }
    data = None
    if body is not None and verb != "GET":
        if isinstance(body, str):
            raw_body = body
        else:
            raw_body = json.dumps(body)
        if len(raw_body) > MAX_BODY_CHARS:
            return _error("body exceeds 20000 characters")
        data = raw_body.encode("utf-8")
        headers["Content-Type"] = "application/json"
    if version:
        headers["LinkedIn-Version"] = str(version).strip()

    request = urllib.request.Request(url, data=data, headers=headers, method=verb)
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            raw = response.read(MAX_BODY_CHARS + 1)
            status = response.status
    except urllib.error.HTTPError as exc:
        raw = exc.read(MAX_BODY_CHARS + 1)
        status = exc.code
    except urllib.error.URLError as exc:
        return _error("linkedin request failed", reason=redact(str(exc.reason), token))

    text = redact(raw.decode("utf-8", "replace"), token)
    truncated = len(raw) > MAX_BODY_CHARS
    if truncated:
        text = text[:MAX_BODY_CHARS]
    parsed: Any
    try:
        parsed = json.loads(text) if text else None
    except json.JSONDecodeError:
        parsed = text

    return {
        "ok": 200 <= status < 300,
        "status": status,
        "method": verb,
        "path": target.split("?", 1)[0],
        "body": parsed,
        "truncated": truncated,
    }


def linkedin_profile() -> dict[str, Any]:
    """Member identity granted by Sign in with LinkedIn (OpenID Connect)."""
    result = linkedin_request("GET", "/v2/userinfo")
    if not result.get("ok"):
        result["grant"] = "openid"
        result["hint"] = (
            "LINKEDIN_ACCESS_TOKEN is only the identity check. "
            "Operate the profile in the Camofox browser at https://www.linkedin.com/."
        )
        return result

    body = result.get("body") if isinstance(result.get("body"), dict) else {}
    keep = (
        "sub",
        "name",
        "given_name",
        "family_name",
        "email",
        "email_verified",
        "locale",
        "picture",
    )
    return {
        "ok": True,
        "status": result["status"],
        "grant": "Sign in with LinkedIn using OpenID Connect",
        "profile": {key: body.get(key) for key in keep if key in body},
        "profile_control": (
            "Identity check only. Operate the profile in the Camofox browser "
            "at https://www.linkedin.com/ while signed in as this member. "
            "If that page is a login wall, ask the human to sign in on the "
            "host noVNC page. Confirm with the human before any public post "
            "or message."
        ),
    }
