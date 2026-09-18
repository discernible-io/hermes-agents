"""nginx TLS sidecar must proxy Passport login, not only /a2a."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RENDER = ROOT / "deploy" / "scripts" / "render-nginx-conf.sh"


def test_nginx_proxies_a2a_and_passport_login(tmp_path):
    out = tmp_path / "nginx.conf"
    env = os.environ.copy()
    env["HERMES_APP_DIR"] = str(tmp_path)
    env["HERMES_PUBLIC_HOST"] = "identyclaw-concierge.identyclaw.com"
    env["HERMES_INGRESS_PORT"] = "10443"
    env["A2A_PORT"] = "9900"
    env["WEBHOOK_PORT"] = "8644"
    env["TELEGRAM_WEBHOOK_PORT"] = "8643"
    subprocess.run(["bash", str(RENDER), str(out)], check=True, env=env, cwd=str(ROOT / "deploy"))
    text = out.read_text(encoding="utf-8")
    assert "location = /a2a" in text
    assert "location ^~ /a2a/" in text
    assert "location ^~ /.well-known/" in text
    assert "location = /api/login" in text
    assert "location = /api/login/timestamp" in text
    assert "proxy_pass http://hermes_a2a;" in text
