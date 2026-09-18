"""Passport JWT A2A overlay: sidecar validate_jwt / login_server and Agent Card extensions.

Behaviour contract (not a snapshot of bundled A2A): inbound identity is a
Passport token_id from the sidecar; outbound login_server uses the peer base
URL with no static bearer; the Agent Card advertises passport-jwt login paths.
"""

from __future__ import annotations

import importlib.util
import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
OVERLAY = ROOT / "packages" / "hermes-identyclaw-a2a"


def _load_security():
    spec = importlib.util.spec_from_file_location(
        "identyclaw_a2a_security", OVERLAY / "security.py"
    )
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def passport():
    mod = _load_security()
    mod.invalidate_login()
    return mod


def test_login_base_url_strips_a2a_rpc_path(passport):
    assert passport.login_base_url("https://hermes.dihola.io:10443/a2a") == "https://hermes.dihola.io:10443"
    assert passport.login_base_url("https://identyclaw-concierge.identyclaw.com:7443") == (
        "https://identyclaw-concierge.identyclaw.com:7443"
    )


def test_agent_card_extensions_advertise_passport_jwt(passport, monkeypatch):
    monkeypatch.delenv("IDENTYCLAW_JWT_AUDIENCE", raising=False)
    monkeypatch.delenv("IDENTYCLAW_JWT_ISSUER", raising=False)
    ext = passport.identyclaw_card_extensions()
    ident = ext["identyclaw"]
    assert ident["auth"] == "passport-jwt"
    assert ident["login"]["timestamp"] == "/api/login/timestamp"
    assert ident["login"]["login"] == "/api/login"
    assert "audience" not in ident
    # Default issuer is always published so peers can verify iss.
    assert ident["issuer"] == "https://api.identyclaw.com"

    monkeypatch.setenv("IDENTYCLAW_JWT_AUDIENCE", "1f02fd08b691062e26ece7200e38c0293612e4aa8b55f45d48d1d10043965a8f")
    monkeypatch.setenv("IDENTYCLAW_JWT_ISSUER", "https://api.identyclaw.com")
    ident = passport.identyclaw_card_extensions()["identyclaw"]
    assert ident["audience"] == "1f02fd08b691062e26ece7200e38c0293612e4aa8b55f45d48d1d10043965a8f"
    assert ident["issuer"] == "https://api.identyclaw.com"


def test_login_base_url_prefers_passport_7443_origin(passport):
    assert passport.login_base_url("https://hermes.dihola.io:7443/a2a") == "https://hermes.dihola.io:7443"
    assert passport.login_base_url("https://hermes.dihola.io:7443/") == "https://hermes.dihola.io:7443"


class _Sidecar(BaseHTTPRequestHandler):
    validated = []
    logins = []

    def log_message(self, format, *args):  # noqa: A002
        return

    def _json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b"{}"
        data = json.loads(raw.decode("utf-8"))
        if self.path == "/validate_jwt":
            token = data.get("token")
            type(self).validated.append(token)
            if token == "good-jwt":
                return self._json(200, {"ok": True, "token_id": "lhsrldbjsnlh"})
            return self._json(401, {"ok": False})
        if self.path == "/login_server":
            type(self).logins.append(data.get("apiEndpoint"))
            return self._json(200, {"ok": True, "jwt": "peer-jwt", "ttl_seconds": 60})
        return self._json(404, {"error": "not found"})


@pytest.fixture
def sidecar_url(passport, monkeypatch):
    _Sidecar.validated = []
    _Sidecar.logins = []
    httpd = HTTPServer(("127.0.0.1", 0), _Sidecar)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{httpd.server_address[1]}"
    monkeypatch.setenv("A2A_AUTH_SIDECAR_URL", url)
    monkeypatch.setenv("IDENTYCLAW_JWT_AUDIENCE", "owner-hex")
    yield url
    httpd.shutdown()
    httpd.server_close()


def test_validate_jwt_returns_passport_token_id(passport, sidecar_url):
    assert passport.validate_jwt("") is None
    assert passport.validate_jwt("bad-jwt") is None
    assert passport.validate_jwt("good-jwt") == "lhsrldbjsnlh"
    assert "good-jwt" in _Sidecar.validated


def test_login_server_uses_peer_base_and_caches(passport, sidecar_url):
    token = passport.login_server("https://hermes.dihola.io:10443/a2a")
    assert token == "peer-jwt"
    again = passport.login_server("https://hermes.dihola.io:10443/a2a")
    assert again == "peer-jwt"
    assert _Sidecar.logins == ["https://hermes.dihola.io:10443"]
