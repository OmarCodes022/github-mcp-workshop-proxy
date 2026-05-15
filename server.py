"""
GitHub MCP Workshop Proxy
=========================
- POST /register              → participant registers their GitHub PAT, gets a clientId
- POST /oauth/token/{clientId} → OAuth2 client_credentials token endpoint
- POST /mcp                   → MCP reverse proxy (forwards with participant's GitHub token)
- GET  /health                → health check
"""

import json
import os
import uuid
import httpx

from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import JSONResponse, Response
from fastapi.middleware.cors import CORSMiddleware


class PrettyJSONResponse(JSONResponse):
    def render(self, content) -> bytes:
        return json.dumps(content, indent=2).encode()


app = FastAPI(title="GitHub MCP Workshop Proxy", default_response_class=PrettyJSONResponse)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

BASE_URL = os.environ.get("BASE_URL", "http://localhost:8000")
GITHUB_MCP_UPSTREAM = os.environ.get(
    "GITHUB_MCP_UPSTREAM", "https://api.githubcopilot.com/mcp/v1"
)

# In-memory store: client_id (UUID) → github_token
# For production use Redis or a DB instead
clients: dict[str, str] = {}


# ─────────────────────────────────────────────
# REGISTRATION
# ─────────────────────────────────────────────
@app.post("/register")
async def register(request: Request):
    body = await request.json()
    github_token: str = body.get("github_token", "").strip()
    name: str = body.get("name", "")

    if not github_token:
        raise HTTPException(status_code=400, detail="github_token is required")

    # Validate the token against GitHub API
    async with httpx.AsyncClient() as client:
        resp = await client.get(
            "https://api.github.com/user",
            headers={
                "Authorization": f"Bearer {github_token}",
                "User-Agent": "github-mcp-workshop-proxy",
            },
        )

    if resp.status_code != 200:
        raise HTTPException(status_code=400, detail="GitHub rejected this token")

    gh_user = resp.json().get("login", name or "unknown")

    # Reuse existing client_id if already registered
    for client_id, token in clients.items():
        if token == github_token:
            return _build_response(client_id, gh_user)

    client_id = str(uuid.uuid4())
    clients[client_id] = github_token
    print(f"[register] {gh_user} → client {client_id[:8]}…")

    return _build_response(client_id, gh_user)


def _build_response(client_id: str, github_user: str) -> dict:
    return {
        "github_user": github_user,
        "agentcore_config": {
            "mcp_endpoint": f"{BASE_URL}/mcp",
            "outbound_auth": "OAuth client → Customised provider → Manual config",
            "client_id": "workshop",
            "client_secret": "workshop",
            "issuer": BASE_URL,
            "authorisation_endpoint": BASE_URL,  # required by form, not called for client_credentials
            "token_endpoint": f"{BASE_URL}/oauth/token/{client_id}",
        },
    }


# ─────────────────────────────────────────────
# OAUTH2 TOKEN ENDPOINT
# AgentCore calls this with client_credentials grant.
# Returns the participant's GitHub PAT as access_token.
# ─────────────────────────────────────────────
@app.post("/oauth/token/{client_id}")
async def oauth_token(client_id: str, request: Request):
    # Accept both JSON and form-encoded bodies (AgentCore sends form-encoded)
    content_type = request.headers.get("content-type", "")
    if "application/x-www-form-urlencoded" in content_type:
        form = await request.form()
        grant_type = form.get("grant_type", "client_credentials")
    else:
        body = await request.json()
        grant_type = body.get("grant_type", "client_credentials")

    if grant_type != "client_credentials":
        return JSONResponse(
            status_code=400,
            content={
                "error": "unsupported_grant_type",
                "error_description": "Only client_credentials is supported",
            },
        )

    github_token = clients.get(client_id)
    if not github_token:
        return JSONResponse(
            status_code=401,
            content={
                "error": "invalid_client",
                "error_description": "Unknown client_id — did you register?",
            },
        )

    print(f"[oauth] token issued for client {client_id[:8]}…")

    return {
        "access_token": github_token,
        "token_type": "Bearer",
        "expires_in": 3600,
    }


# ─────────────────────────────────────────────
# MCP PROXY
# By the time a request arrives here, AgentCore has
# already fetched the GitHub token via /oauth/token/{id}
# and attached it as  Authorization: Bearer ghp_...
# We just forward it to the GitHub MCP server.
# ─────────────────────────────────────────────
@app.post("/mcp")
async def mcp_proxy(request: Request):
    auth = request.headers.get("authorization", "")
    github_token = auth.removeprefix("Bearer ").strip()

    if not github_token:
        return JSONResponse(
            status_code=401,
            content={
                "jsonrpc": "2.0",
                "error": {"code": -32001, "message": "Missing Authorization header"},
                "id": None,
            },
        )

    body = await request.body()

    forward_headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {github_token}",
        "User-Agent": "github-mcp-workshop-proxy",
    }
    if session_id := request.headers.get("mcp-session-id"):
        forward_headers["mcp-session-id"] = session_id

    pid = github_token[-8:]
    method = "(unknown)"
    try:
        method = __import__("json").loads(body).get("method", method)
    except Exception:
        pass
    print(f"[mcp] token:…{pid} method:{method}")

    async with httpx.AsyncClient(timeout=30) as client:
        try:
            upstream_resp = await client.post(
                GITHUB_MCP_UPSTREAM,
                content=body,
                headers=forward_headers,
            )
        except httpx.RequestError as exc:
            return JSONResponse(
                status_code=502,
                content={
                    "jsonrpc": "2.0",
                    "error": {"code": -32603, "message": f"Upstream error: {exc}"},
                    "id": None,
                },
            )

    return Response(
        content=upstream_resp.content,
        status_code=upstream_resp.status_code,
        media_type=upstream_resp.headers.get("content-type", "application/json"),
    )


# ─────────────────────────────────────────────
# HEALTH
# ─────────────────────────────────────────────
@app.get("/health")
async def health():
    return {"status": "ok", "participants": len(clients)}
