"""Official LinkedIn API plugin. Uses LINKEDIN_ACCESS_TOKEN from the environment."""

from __future__ import annotations

import logging
from pathlib import Path

logger = logging.getLogger(__name__)

__all__ = ["register"]


def register(ctx) -> None:
    try:
        from . import schemas, tools
    except ImportError:
        import schemas  # type: ignore
        import tools  # type: ignore

    registrations = (
        ("linkedin_profile", schemas.PROFILE, tools.linkedin_profile),
        ("linkedin_api", schemas.API, tools.linkedin_api),
    )
    for name, schema, handler in registrations:
        try:
            ctx.register_tool(
                name=name,
                toolset="linkedin",
                schema=schema,
                handler=handler,
                requires_env=["LINKEDIN_ACCESS_TOKEN"],
            )
        except Exception:
            logger.warning("linkedin: failed to register tool %s", name, exc_info=True)

    skill_md = Path(__file__).resolve().parent / "skills" / "linkedin" / "SKILL.md"
    if skill_md.is_file():
        try:
            ctx.register_skill("linkedin", skill_md)
        except Exception:
            logger.warning("linkedin: failed to register skill", exc_info=True)
    else:
        logger.warning("linkedin: skill missing at %s", skill_md)
