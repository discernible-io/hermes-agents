"""Passport JWT security context — identity is token_id via auth sidecar."""

from __future__ import annotations

import hmac
import logging
import os
from dataclasses import dataclass
from typing import Optional

from gateway.platforms._shared import profile_scoped as _profile_scoped

logger = logging.getLogger(__name__)


def _startup_env(name: str) -> str:
    if _profile_scoped():
        from agent.secret_scope import get_secret

        return (get_secret(name) or "").strip()
    return os.getenv(name, "").strip()


@dataclass(frozen=True)
class PassportA2ASecurityContext:
    """Passport JWT auth; falls back to static tokens when JWT audience unset."""

    jwt_audience: str
    jwt_issuer: str
    bearer_token: str
    peer_tokens: tuple[tuple[str, str], ...]
    trusted_peers: frozenset[str]
    allow_all_users: bool
    requested_host: str
    push_secret: str

    @classmethod
    def capture(cls) -> "PassportA2ASecurityContext":
        from plugins.platforms.a2a.security import A2ASecurityContext

        base = A2ASecurityContext.capture()
        return cls(
            jwt_audience=_startup_env("IDENTYCLAW_JWT_AUDIENCE"),
            jwt_issuer=(_startup_env("IDENTYCLAW_JWT_ISSUER") or _startup_env("A2A_PUBLIC_URL")).rstrip(
                "/"
            ),
            bearer_token=base.bearer_token,
            peer_tokens=base.peer_tokens,
            trusted_peers=base.trusted_peers,
            allow_all_users=base.allow_all_users,
            requested_host=base.requested_host,
            push_secret=base.push_secret,
        )

    def passport_mode(self) -> bool:
        return bool(self.jwt_audience)

    def localhost_only(self) -> bool:
        if self.passport_mode():
            return False
        return not (self.bearer_token or self.peer_tokens)

    def resolve_bind_host(self) -> str:
        if self.requested_host in {"127.0.0.1", "localhost", "::1"}:
            return self.requested_host
        if self.localhost_only():
            logger.warning(
                "IdentyClaw A2A: A2A_HOST=%s ignored — set IDENTYCLAW_JWT_AUDIENCE "
                "(Passport) or A2A_PEER_TOKENS / A2A_BEARER_TOKEN; binding 127.0.0.1.",
                self.requested_host,
            )
            return "127.0.0.1"
        return self.requested_host

    def authenticate(self, auth_header: Optional[str], client_ip: str = "") -> Optional[str]:
        if self.localhost_only():
            return f"ip:{client_ip or 'local'}"
        parts = (auth_header or "").split(None, 1)
        if len(parts) != 2 or parts[0].lower() != "bearer":
            return None
        presented = parts[1].strip()
        if not presented:
            return None

        if self.passport_mode():
            try:
                from . import sidecar_client

                result = sidecar_client.validate_jwt(
                    presented,
                    audience=self.jwt_audience,
                    issuer=self.jwt_issuer or None,
                )
                if result.get("valid") and result.get("identity"):
                    return str(result["identity"])
                if result.get("valid") and result.get("token_id"):
                    return str(result["token_id"])
            except Exception:
                # Fall through to static peer/bearer tokens; a non-JWT
                # Authorization header must not fail closed before that.
                logger.warning("IdentyClaw A2A: JWT validation via sidecar failed", exc_info=True)

        for token, name in self.peer_tokens:
            if hmac.compare_digest(presented, token):
                return name
        if self.bearer_token and hmac.compare_digest(presented, self.bearer_token):
            return f"ip:{client_ip or 'unknown'}"
        return None

    def is_trusted_peer(self, identity: str) -> bool:
        if self.allow_all_users or not self.trusted_peers:
            return True
        return identity in self.trusted_peers
