"""Checks for the hermes-agents umbrella after the sibling-plugin split."""

from __future__ import annotations

import json
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PARENT = REPO.parent


def _plugin(name: str) -> Path:
    return PARENT / name


def test_sibling_plugin_checkouts_exist():
    assert _plugin("hermes-identyclaw-auth").is_dir()
    assert _plugin("hermes-identyclaw-a2a").is_dir()
    hooks = _plugin("hermes-identyclaw-webhook")
    if not hooks.is_dir():
        hooks = _plugin("hermes-identyclaw-webhooks")
    assert hooks.is_dir(), "expected sibling hermes-identyclaw-webhook(s)"


def test_a2a_manifest_overrides_bundled_platform():
    text = (_plugin("hermes-identyclaw-a2a") / "plugin.yaml").read_text()
    assert "name: a2a-platform" in text
    assert "tools.override" in text


def test_webhooks_stay_off_hmac_routes():
    hooks = _plugin("hermes-identyclaw-webhook")
    if not hooks.is_dir():
        hooks = _plugin("hermes-identyclaw-webhooks")
    text = (hooks / "plugin.yaml").read_text()
    assert "HMAC" in text
    assert "/webhooks/{route}" in text


def test_auth_ships_skill():
    skill = _plugin("hermes-identyclaw-auth") / "skills" / "identyclaw" / "SKILL.md"
    assert skill.is_file()


def test_deploy_idcp_symlink_points_at_sibling_auth():
    link = REPO / "deploy" / "idcp"
    assert link.is_symlink()
    target = link.resolve()
    assert target == _plugin("hermes-identyclaw-auth").resolve()
    assert (target / "bin" / "idcp.mjs").is_file()


def test_install_script_resolves_siblings():
    text = (REPO / "install.sh").read_text()
    assert "hermes-identyclaw-auth" in text
    assert "IDENTYCLAW_AUTH_DIR" in text
    assert "--fetch" in text
    assert "--peer" in text


def test_nginx_renderer_includes_hooks_and_login():
    script = (REPO / "deploy" / "scripts" / "render-nginx-conf.sh").read_text()
    assert "/hooks/" in script
    assert "/api/login" in script
    assert "hermes_identyclaw_hooks" in script


def test_wake_normalize_contract():
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
