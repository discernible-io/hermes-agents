"""Tool schemas — what the agent sees for the official LinkedIn app."""

from __future__ import annotations

PROFILE = {
    "name": "linkedin_profile",
    "description": (
        "Read which LinkedIn member LINKEDIN_ACCESS_TOKEN belongs to "
        "(name, email, photo, member id). This is an identity check. "
        "Feed, messages, posts, and profile edits are done in the Camofox "
        "browser while signed in at https://www.linkedin.com/. Never ask "
        "for or print the access token."
    ),
    "parameters": {"type": "object", "properties": {}, "required": []},
}

API = {
    "name": "linkedin_api",
    "description": (
        "Call https://api.linkedin.com with the host-injected "
        "LINKEDIN_ACCESS_TOKEN. Pass a relative path such as /v2/userinfo. "
        "Profile actions (feed, messages, posts, edits) go through the "
        "signed-in Camofox browser, not this token. Confirm with the human "
        "before any POST, PUT, PATCH, or DELETE. Never print the access token."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "method": {
                "type": "string",
                "description": "HTTP method: GET, POST, PUT, PATCH, or DELETE",
            },
            "path": {
                "type": "string",
                "description": "Relative LinkedIn path, for example /v2/userinfo",
            },
            "body": {
                "description": "JSON object or string for write requests",
            },
            "version": {
                "type": "string",
                "description": "LinkedIn-Version header (YYYYMM) for /rest/ calls",
            },
        },
        "required": ["method", "path"],
    },
}
