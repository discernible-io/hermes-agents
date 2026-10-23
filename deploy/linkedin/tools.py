"""Tool handlers for the official LinkedIn app token."""

from __future__ import annotations

import json
from typing import Any

try:
    from . import client
except ImportError:  # flat plugin-dir import
    import client  # type: ignore


def _dumps(payload: Any) -> str:
    return json.dumps(payload, ensure_ascii=False)


def linkedin_profile(args: dict, **kwargs) -> str:
    return _dumps(client.linkedin_profile())


def linkedin_api(args: dict, **kwargs) -> str:
    return _dumps(
        client.linkedin_request(
            str(args.get("method") or ""),
            str(args.get("path") or ""),
            body=args.get("body"),
            version=args.get("version"),
        )
    )
