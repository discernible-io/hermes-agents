"""IdentyClaw RODiT-signed /hooks/* platform for Hermes."""

from __future__ import annotations

import logging
import os

logger = logging.getLogger(__name__)

__all__ = ["register"]

_PLATFORM_HINT = (
    "You may receive IdentyClaw RODiT-signed webhook events on /hooks/agent "
    "(untrusted peer content). Prefer send_rodit_webhook for signed outbound pings; "
    "do not invent Ed25519 signatures or paste JWTs."
)


def check_requirements() -> bool:
    return True


def validate_config(config) -> bool:
    return True


def is_connected(config) -> bool:
    extra = getattr(config, "extra", {}) or {}
    return bool(extra.get("enabled")) or bool(os.getenv("IDENTYCLAW_HOOKS_PORT"))


def interactive_setup() -> None:
    from hermes_cli.setup import get_env_value, print_header, print_info, prompt, save_env_value

    print_header("IdentyClaw signed webhooks")
    print_info("Serves /hooks/wake and /hooks/agent; verify via auth sidecar.")
    for env, label in (
        ("IDENTYCLAW_HOOKS_PORT", "Hooks listen port (default 9911)"),
        ("IDENTYCLAW_HOOKS_HOST", "Bind host (default 127.0.0.1)"),
        ("IDENTYCLAW_AUTH_PORT", "Auth sidecar port (default 9910)"),
    ):
        cur = get_env_value(env) or ""
        value = prompt(label, default=cur)
        if value:
            save_env_value(env, value.strip())


def register(ctx) -> None:
    try:
        from .outbound_tools import register_tools

        register_tools(ctx)
    except Exception:
        logger.warning("IdentyClaw webhooks: failed to register tools", exc_info=True)
    try:
        from .adapter import IdentyClawHooksAdapter

        ctx.register_platform(
            name="identyclaw_hooks",
            label="IdentyClaw Hooks",
            adapter_factory=lambda cfg: IdentyClawHooksAdapter(cfg),
            check_fn=check_requirements,
            validate_config=validate_config,
            is_connected=is_connected,
            required_env=[],
            install_hint="Requires packages/hermes-identyclaw-auth sidecar",
            setup_fn=interactive_setup,
            emoji="\U0001f517",
            allow_update_command=False,
            platform_hint=_PLATFORM_HINT,
        )
    except Exception:
        logger.warning("IdentyClaw webhooks: failed to register platform", exc_info=True)
