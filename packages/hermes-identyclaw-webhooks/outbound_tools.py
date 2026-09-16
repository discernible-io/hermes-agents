"""send_rodit_webhook tool — signs and delivers via auth sidecar."""

from __future__ import annotations

import json
import logging
from typing import Any

logger = logging.getLogger(__name__)


def _hooks_available() -> bool:
    return True


def send_rodit_webhook(args: dict, **_: Any) -> str:
    peer = str(args.get("peer") or args.get("peer_id") or args.get("peerId") or "").strip()
    url = str(args.get("url") or args.get("peer_url") or args.get("peerBaseUrl") or "").strip()
    text = str(args.get("text") or args.get("message") or args.get("event") or "").strip()
    hook_path = str(args.get("hook_path") or args.get("hookPath") or "hooks/wake").strip()
    if not url and not peer:
        return "Error: provide 'url' (peer gateway HTTPS base) or 'peer' token_id with resolvable URL."
    if not url:
        return (
            f"Error: peer '{peer}' needs an explicit 'url' (Passport metadata.webhook_url base). "
            "Pass url=https://peer.example.com"
        )
    if not text:
        text = f"Webhook ping via send_rodit_webhook"
    try:
        from .sidecar_client import send_webhook

        result = send_webhook(
            url,
            hook_path=hook_path,
            text=text,
            session_rodit_id=peer,
        )
    except Exception as e:
        return f"Error: send_rodit_webhook failed — {e}"
    ok = bool(result.get("ok"))
    status = 200 if ok else 502
    # Never echo secrets; summarize.
    return json.dumps(
        {
            "ok": ok,
            "status": status,
            "url": result.get("url") or url,
            "peer": peer or None,
            "hook_path": hook_path,
            "detail": result.get("response", {}).get("error")
            or ("delivered" if ok else result.get("error") or "failed"),
        },
        indent=2,
    )


def register_tools(ctx) -> None:
    ctx.register_tool(
        name="send_rodit_webhook",
        toolset="identyclaw_hooks",
        handler=send_rodit_webhook,
        description=(
            "Send a RODiT-signed webhook to a peer gateway (/hooks/wake or /hooks/agent). "
            "Requires the IdentyClaw auth sidecar. Never invent signatures or paste JWTs."
        ),
        schema={
            "type": "object",
            "properties": {
                "url": {
                    "type": "string",
                    "description": "Peer gateway HTTPS base (Passport metadata.webhook_url), no path.",
                },
                "peer": {
                    "type": "string",
                    "description": "Optional peer token_id for session binding.",
                },
                "text": {
                    "type": "string",
                    "description": "Wake/event text payload.",
                },
                "hook_path": {
                    "type": "string",
                    "description": "hooks/wake (default) or hooks/agent.",
                },
            },
            "required": ["url"],
        },
        check_fn=_hooks_available,
    )
