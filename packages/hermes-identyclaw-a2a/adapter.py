"""Inbound A2A adapter overlay: Passport JWT via sidecar, Agent Card identyclaw extensions."""

from __future__ import annotations

import logging
import os
from http.server import ThreadingHTTPServer
from typing import Optional

from plugins.platforms.a2a.adapter import A2AAdapter, A2ARequestHandler, _daemon_thread
from plugins.platforms.a2a.security import A2ASecurityContext

from . import security as passport

logger = logging.getLogger(__name__)

_LOGIN_GET = {"/api/login/timestamp"}
_LOGIN_POST = {"/api/login"}


class PassportSecurityContext(A2ASecurityContext):
    """Require a Passport JWT on POST even when nginx fronts a localhost bind."""

    def localhost_only(self) -> bool:
        return False

    def resolve_bind_host(self) -> str:
        requested = (self.requested_host or "127.0.0.1").strip() or "127.0.0.1"
        return requested

    def authenticate(self, auth_header: Optional[str], client_ip: str = "") -> Optional[str]:
        parts = (auth_header or "").split(None, 1)
        if len(parts) != 2 or parts[0].lower() != "bearer":
            return None
        return passport.validate_jwt(parts[1].strip())


class PassportA2ARequestHandler(A2ARequestHandler):
    def _raw_bytes(self) -> bytes:
        try:
            length = int(self.headers.get("Content-Length", 0) or 0)
        except ValueError:
            length = 0
        return self.rfile.read(length) if length else b""

    def _proxy_login(self, method: str, path: str) -> None:
        body = self._raw_bytes() if method == "POST" else b""
        ctype = self.headers.get("Content-Type") or "application/json"
        status, payload, out_type = passport.proxy_sidecar(method, path, body, ctype)
        self.send_response(status)
        raw = payload if isinstance(payload, (bytes, bytearray)) else payload.encode("utf-8")
        self.send_header("Content-Type", out_type or "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):  # noqa: N802
        route = self.adapter._route_for_path(self.path)
        subpath = (route.get("subpath") or "/").rstrip("/") or "/"
        if subpath in _LOGIN_GET:
            return self._proxy_login("GET", subpath)
        return super().do_GET()

    def do_POST(self):  # noqa: N802
        route = self.adapter._route_for_path(self.path)
        subpath = (route.get("subpath") or "/").rstrip("/") or "/"
        if subpath in _LOGIN_POST:
            return self._proxy_login("POST", subpath)
        return super().do_POST()


class PassportA2AAdapter(A2AAdapter):
    """Bundled A2A inbound server with Passport JWT auth and Agent Card extensions."""

    def __init__(self, config, **kwargs):
        super().__init__(config=config, **kwargs)
        captured = A2ASecurityContext.capture()
        self._security_context = PassportSecurityContext(
            bearer_token="",
            peer_tokens=(),
            trusted_peers=captured.trusted_peers,
            allow_all_users=True,
            requested_host=os.getenv("A2A_HOST") or "127.0.0.1",
            push_secret=captured.push_secret,
        )
        # nginx in the pod talks to loopback; keep bind local unless the operator widens it.
        self.host = self._security_context.resolve_bind_host()

    def _build_card(self, public_url: Optional[str] = None, agent: Optional[dict] = None) -> dict:
        card = super()._build_card(public_url, agent=agent)
        extensions = card.setdefault("extensions", {})
        if not isinstance(extensions, dict):
            extensions = {}
            card["extensions"] = extensions
        extensions.update(passport.identyclaw_card_extensions())
        card["securitySchemes"] = {"bearer": {"type": "http", "scheme": "bearer"}}
        card["security"] = [{"bearer": []}]
        return card

    async def connect(self, **_kwargs) -> bool:
        import asyncio

        self._loop = asyncio.get_running_loop()
        try:
            self._httpd = ThreadingHTTPServer((self.host, self.port), PassportA2ARequestHandler)
        except OSError as e:
            logger.error("A2A: could not bind %s:%s — %s", self.host, self.port, e)
            self._set_fatal_error("bind_failed", f"A2A bind failed: {e}", retryable=True)
            return False
        self._httpd.daemon_threads = True
        self._httpd.adapter = self  # type: ignore[attr-defined]
        self._server_thread = _daemon_thread(self._httpd.serve_forever, "a2a-http")
        self._watchdog_stop.clear()
        self._watchdog_thread = _daemon_thread(self._watchdog_loop, "a2a-watchdog")
        self._mark_connected()
        logger.info(
            "A2A: Passport JWT overlay on http://%s:%s as %r (sidecar %s)",
            self.host, self.port, self.agent_name, passport.sidecar_url(),
        )
        self._wire_plugin_handlers(None)
        return True
