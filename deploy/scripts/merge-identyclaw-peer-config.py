#!/usr/bin/env python3
"""Merge IdentyClaw peer plugin enablement into Hermes config.yaml.

Never append a second top-level plugins:/platforms: block — YAML last-wins
would wipe Telegram/webhook settings.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print(
        "pyyaml missing — enable identyclaw-auth + identyclaw-a2a + identyclaw-webhooks in config.yaml manually",
        file=sys.stderr,
    )
    raise SystemExit(0)

MARKER = "# identyclaw-peer (managed by hermes.sh identyclaw-peer-install)"


def first_mapping_block(src: str, key: str):
    m = re.search(rf"(?ms)^{re.escape(key)}:\n(.*?)(?=^[a-zA-Z_][\w-]*:|\Z)", src)
    if not m:
        return None
    try:
        return (yaml.safe_load(f"{key}:\n{m.group(1)}") or {}).get(key)
    except Exception:
        return None


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <hermes-app-dir>", file=sys.stderr)
        return 2
    app = Path(sys.argv[1])
    cfg = app / "config.yaml"
    if not cfg.is_file():
        print(f"skip config enablement — missing {cfg}")
        return 0

    text = cfg.read_text()
    data = yaml.safe_load(text) or {}
    if not isinstance(data, dict):
        print(f"skip config enablement — {cfg} root is not a mapping", file=sys.stderr)
        return 0

    # Recover first platforms map if a prior append duplicated top-level keys.
    if len(re.findall(r"(?m)^platforms:\s*$", text)) > 1:
        first = first_mapping_block(text, "platforms")
        if isinstance(first, dict):
            merged = dict(first)
            merged.update(data.get("platforms") or {})
            data["platforms"] = merged

    plugins = data.setdefault("plugins", {})
    if not isinstance(plugins, dict):
        plugins = {}
        data["plugins"] = plugins
    enabled = plugins.setdefault("enabled", [])
    if not isinstance(enabled, list):
        enabled = []
        plugins["enabled"] = enabled
    # Drop legacy install-dir id (yaml name a2a-platform hits bundled platforms/a2a).
    while "a2a-platform" in enabled:
        enabled.remove("a2a-platform")
    for name in ("identyclaw-auth", "identyclaw-a2a", "identyclaw-webhooks"):
        if name not in enabled:
            enabled.append(name)
    disabled = plugins.setdefault("disabled", [])
    if not isinstance(disabled, list):
        disabled = []
        plugins["disabled"] = disabled
    if "platforms/a2a" not in disabled:
        disabled.append("platforms/a2a")

    entries = plugins.setdefault("entries", {})
    if not isinstance(entries, dict):
        entries = {}
        plugins["entries"] = entries
    # Prefer unique plugin id; keep a2a-platform entry only if already present for migration.
    entries.pop("a2a-platform", None)
    for plug_id, allow_override in (
        ("identyclaw-auth", False),
        ("identyclaw-a2a", True),
        ("identyclaw-webhooks", False),
    ):
        entry = entries.setdefault(plug_id, {})
        if not isinstance(entry, dict):
            entry = {}
            entries[plug_id] = entry
        entry["enabled"] = True
        if allow_override:
            entry["allow_tool_override"] = True
            caps = entry.setdefault("granted_capabilities", [])
            if not isinstance(caps, list):
                caps = []
                entry["granted_capabilities"] = caps
            if "tools.override" not in caps:
                caps.append("tools.override")

    platforms = data.setdefault("platforms", {})
    if not isinstance(platforms, dict):
        platforms = {}
        data["platforms"] = platforms
    # Bundled A2A stays off; overlay owns inbound via identyclaw-a2a.
    a2a_plat = platforms.setdefault("a2a", {})
    if not isinstance(a2a_plat, dict):
        a2a_plat = {}
        platforms["a2a"] = a2a_plat
    a2a_plat["enabled"] = True
    ih = platforms.setdefault("identyclaw_hooks", {})
    if not isinstance(ih, dict):
        ih = {}
        platforms["identyclaw_hooks"] = ih
    ih["enabled"] = True

    out = yaml.safe_dump(data, sort_keys=False, default_flow_style=False)
    if MARKER not in out:
        out = out.rstrip() + f"\n\n{MARKER}\n"
    if not out.endswith("\n"):
        out += "\n"
    cfg.write_text(out)
    print(f"Merged identyclaw-peer plugin enablement into {cfg}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
