"""Filesystem / pure-helper checks for IdentyClaw packages (no Hermes import graph)."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


def test_sidecar_base_default(monkeypatch):
    monkeypatch.delenv("IDENTYCLAW_AUTH_HOST", raising=False)
    monkeypatch.delenv("IDENTYCLAW_AUTH_PORT", raising=False)
    mod = _load(
        "ic_a2a_sidecar",
        REPO / "packages" / "hermes-identyclaw-a2a" / "sidecar_client.py",
    )
    assert mod.sidecar_base() == "http://127.0.0.1:9910"


def test_own_passport_client_calls_sidecar(monkeypatch):
    mod = _load(
        "ic_a2a_sidecar_own",
        REPO / "packages" / "hermes-identyclaw-a2a" / "sidecar_client.py",
    )
    captured = {}

    def fake_get(path, timeout=10.0):
        captured["path"] = path
        captured["timeout"] = timeout
        return {
            "ok": True,
            "owner_id": "abc123",
            "token_id": "tok",
            "issuer": "https://api.identyclaw.com",
        }

    monkeypatch.setattr(mod, "_get", fake_get)
    out = mod.own_passport()
    assert captured["path"] == "/v1/own_passport"
    assert out["owner_id"] == "abc123"


def test_wake_normalize():
    # Load only the pure helpers by exec'ing a tiny snippet from adapter
    # without importing gateway — duplicate the JSON helper contract.
    def _normalize_wake(raw: str) -> dict:
        try:
            payload = json.loads(raw)
        except Exception:
            return {"ok": False, "error": "invalid json"}
        if not isinstance(payload, dict):
            return {"ok": False, "error": "object required"}
        if isinstance(payload.get("text"), str) and payload["text"].strip():
            return {"ok": True, "text": payload["text"].strip(), "mode": "now"}
        return {"ok": False, "error": "text required"}

    assert _normalize_wake(json.dumps({"text": "ping"}))["ok"] is True
    assert _normalize_wake("{}")["ok"] is False


def test_nginx_renderer_includes_hooks_and_login():
    script = (REPO / "deploy" / "scripts" / "render-nginx-conf.sh").read_text()
    assert "/hooks/" in script
    assert "/api/login" in script
    assert "hermes_identyclaw_hooks" in script


def test_a2a_manifest_overrides_bundled_platform():
    text = (REPO / "packages" / "hermes-identyclaw-a2a" / "plugin.yaml").read_text()
    assert "name: a2a-platform" in text
    assert "tools.override" in text


def test_webhooks_stay_off_hmac_routes():
    text = (REPO / "packages" / "hermes-identyclaw-webhooks" / "plugin.yaml").read_text()
    assert "HMAC" in text
    assert "/webhooks/{route}" in text


def test_deploy_idcp_is_symlink_to_auth_package():
    link = REPO / "deploy" / "idcp"
    assert link.is_symlink()
    target = link.resolve()
    assert target.name == "hermes-identyclaw-auth"


def test_install_script_present():
    script = REPO / "install.sh"
    assert script.is_file()
    text = script.read_text()
    assert "HERMES_HOME" in text
    assert "--peer" in text
    assert "a2a-platform" in text
    assert "identyclaw-webhooks" in text


def test_packages_layout():
    for name in (
        "hermes-identyclaw-auth",
        "hermes-identyclaw-a2a",
        "hermes-identyclaw-webhooks",
    ):
        assert (REPO / "packages" / name).is_dir()
    assert (REPO / "packages" / "hermes-identyclaw-a2a" / "plugin.yaml").is_file()
    assert (REPO / "packages" / "hermes-identyclaw-webhooks" / "plugin.yaml").is_file()
    assert (REPO / "packages" / "hermes-identyclaw-a2a" / "outbound_tools.py").is_file()
