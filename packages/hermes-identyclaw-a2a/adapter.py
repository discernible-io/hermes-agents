"""Subclass bundled A2AAdapter: Passport security + /api/login* routes."""

from __future__ import annotations

import asyncio
import json
import logging
from http.server import ThreadingHTTPServer
from typing import Optional

from plugins.platforms.a2a.adapter import A2AAdapter, A2ARequestHandler, _daemon_thread

from .security import PassportA2ASecurityContext

logger = logging.getLogger(__name__)


class IdentyClawA2ARequestHandler(A2ARequestHandler):
    """Extends bundled handler with RODiT login routes (proxied to auth sidecar)."""

    def do_GET(self):  # noqa: N802
        route = self.adapter._route_for_path(self.path)
        subpath = route["subpath"].rstrip("/") or "/"
        if subpath == "/api/login/timestamp":
            return self._proxy_login_timestamp()
        return super().do_GET()

    def do_POST(self):  # noqa: N802
        route = self.adapter._route_for_path(self.path)
        subpath = route["subpath"].rstrip("/") or "/"
        if subpath == "/api/login":
            return self._proxy_login()
        return super().do_POST()

    def _proxy_login_timestamp(self) -> None:
        try:
            from . import sidecar_client

            payload = sidecar_client.proxy_login_timestamp()
            self._json(200, payload)
        except Exception as e:
            logger.warning("IdentyClaw A2A: login timestamp proxy failed: %s", e)
            self._json(502, {"error": {"code": "SIDECAR_UNAVAILABLE", "message": str(e)}})

    def _proxy_login(self) -> None:
        try:
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            body = json.loads(raw.decode("utf-8") or "{}")
            if not isinstance(body, dict):
                return self._json(
                    400, {"error": {"code": "INVALID_JSON", "message": "object required"}}
                )
            from . import sidecar_client

            status, payload = sidecar_client.proxy_login(body)
            self._json(status, payload)
        except Exception as e:
            logger.warning("IdentyClaw A2A: login proxy failed: %s", e)
            self._json(502, {"error": {"code": "SIDECAR_UNAVAILABLE", "message": str(e)}})


class IdentyClawA2AAdapter(A2AAdapter):
    """Bundled A2A plus Passport JWT security context and login routes."""

    def __init__(self, config, **kwargs):
        super().__init__(config=config, **kwargs)
        self._security_context = PassportA2ASecurityContext.capture()
        self.host = self._security_context.resolve_bind_host()

    def _build_card(self, public_url: Optional[str] = None, agent: Optional[dict] = None) -> dict:
        card = super()._build_card(public_url=public_url, agent=agent)
        ext = card.setdefault("extensions", {})
        ident = ext.setdefault("identyclaw", {})
        sec = self._security_context
        if isinstance(sec, PassportA2ASecurityContext) and sec.jwt_audience:
            ident["auth"] = "passport-jwt"
            ident["audience"] = sec.jwt_audience
            if sec.jwt_issuer:
                ident["issuer"] = sec.jwt_issuer
            ident["login"] = {
                "timestamp": "/api/login/timestamp",
                "login": "/api/login",
            }
        card["securitySchemes"] = {"bearer": {"type": "http", "scheme": "bearer"}}
        card["security"] = [{"bearer": []}]
        return card

    async def connect(self, **_kwargs) -> bool:
        self._loop = asyncio.get_running_loop()
        try:
            self._httpd = ThreadingHTTPServer(
                (self.host, self.port), IdentyClawA2ARequestHandler
            )
        except OSError as e:
            logger.error("IdentyClaw A2A: could not bind %s:%s — %s", self.host, self.port, e)
            self._set_fatal_error("bind_failed", f"A2A bind failed: {e}", retryable=True)
            return False
        self._httpd.daemon_threads = True
        self._httpd.adapter = self  # type: ignore[attr-defined]
        self._server_thread = _daemon_thread(self._httpd.serve_forever, "a2a-http")
        self._watchdog_stop.clear()
        self._watchdog_thread = _daemon_thread(self._watchdog_loop, "a2a-watchdog")
        self._mark_connected()
        passport = (
            isinstance(self._security_context, PassportA2ASecurityContext)
            and self._security_context.passport_mode()
        )
        logger.info(
            "IdentyClaw A2A: serving on http://%s:%s (passport_jwt=%s) as %r",
            self.host,
            self.port,
            passport,
            self.agent_name,
        )
        self._wire_plugin_handlers(None)
        return True
