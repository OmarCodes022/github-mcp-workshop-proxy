# github-mcp-workshop-proxy

Multi-tenant OAuth proxy that lets workshop participants connect their GitHub PAT to Amazon Bedrock AgentCore via a shared MCP gateway.

## The problem

AgentCore requires OAuth2 `client_credentials` to authenticate against an MCP server. The GitHub MCP server just takes a Bearer PAT - no OAuth. And it can't serve multiple participants with different identities from one endpoint.

## The solution

This proxy sits between AgentCore and the GitHub MCP server:

```
Participant
  POST /register {github_token}
    gets back token_endpoint: https://your-proxy/oauth/token/<their-uuid>

AgentCore (per invocation)
  POST /oauth/token/<uuid>  →  returns participant's GitHub PAT as access_token
  POST /mcp                 →  proxy forwards to github-mcp-server with their PAT
    github-mcp-server       →  calls GitHub API
```

Each participant gets a unique token endpoint URL containing their UUID. AgentCore uses `client_credentials` to fetch their PAT, then calls the shared `/mcp` endpoint. The proxy forwards the PAT to a self-hosted `github-mcp-server` instance running on the same EC2.

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/register` | Submit GitHub PAT, get back AgentCore OAuth config |
| `POST` | `/oauth/token/{client_id}` | OAuth2 token endpoint (called by AgentCore) |
| `POST` | `/mcp` | MCP reverse proxy to github-mcp-server |
| `GET`  | `/health` | Health check |

### Register

```bash
curl -s -X POST https://your-proxy/register \
  -H "Content-Type: application/json" \
  -d '{"github_token": "ghp_...", "name": "alice"}' | python3 -m json.tool
```

Response:
```json
{
  "github_user": "alice",
  "agentcore_config": {
    "mcp_endpoint": "https://your-proxy/mcp",
    "client_id": "workshop",
    "client_secret": "workshop",
    "issuer": "https://your-proxy",
    "authorisation_endpoint": "https://your-proxy",
    "token_endpoint": "https://your-proxy/oauth/token/<uuid>"
  }
}
```

Participants paste these values into the AgentCore OAuth client form.

## Architecture

```
EC2 t3.small (Ubuntu 24.04)
  nginx (443)
    github-mcp-proxy  :8000  (FastAPI + uvicorn)
    github-mcp-server :8082  (Docker, internal only)
```

The github-mcp-server Docker container runs in HTTP mode with `--network host`. Port 8082 is not exposed in the security group - only nginx (80/443) and SSH (22) are public.

## Deploy

### Prerequisites

- AWS CLI configured
- EC2 key pair (name + `.pem` file)
- Domain name pointing at the Elastic IP (required for HTTPS, which AgentCore requires)

### First deploy

```bash
# HTTP only (get the Elastic IP first, then set up DNS)
EC2_KEY=~/.ssh/workshop.pem KEY_NAME=workshop ./deploy.sh

# With TLS (point DNS A record at the Elastic IP first)
EC2_KEY=~/.ssh/workshop.pem KEY_NAME=workshop DOMAIN=proxy.example.com ./deploy.sh
```

### Redeploy after code changes

Same command - CloudFormation is a no-op if infra hasn't changed, only app files update.

### Teardown

```bash
aws cloudformation delete-stack --stack-name github-mcp-proxy
```

## Workshop participant flow

1. Get the proxy URL from the workshop instructor
2. Register with your GitHub PAT:
   ```bash
   curl -s -X POST https://<proxy>/register \
     -H "Content-Type: application/json" \
     -d '{"github_token": "ghp_...", "name": "yourname"}' | python3 -m json.tool
   ```
3. In AgentCore - Identity - add an OAuth client (Customised provider, Manual config):
   - Client ID / Secret: `workshop` / `workshop`
   - Issuer: value from response
   - Authorisation endpoint: value from response
   - Token endpoint: your unique `token_endpoint` from response
4. Create an AgentCore gateway - MCP target pointing at `https://<proxy>/mcp`, outbound auth = your OAuth client
5. Attach the gateway to your AgentCore Harness agent

## Infrastructure (CloudFormation)

`template.yaml` creates:

| Resource | Details |
|----------|---------|
| EC2 instance | Ubuntu 24.04, t3.small (handles ~50 participants) |
| Elastic IP | Static - survives stop/start |
| Security group | Inbound: 22, 80, 443 |
| IAM role | SSM Session Manager access |

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BASE_URL` | `http://localhost:8000` | Public URL returned in `/register` responses |
| `GITHUB_MCP_UPSTREAM` | `http://127.0.0.1:8082` | github-mcp-server endpoint |

## Notes

- Participant registrations are in-memory and lost on server restart. Re-register and update the OAuth client token endpoint after any restart.
- The `client_id` and `client_secret` (`workshop`/`workshop`) are the same for all participants - the actual per-participant secret is the UUID in the token endpoint URL.
- For 100+ participants use a `t3.medium` instance: `InstanceType=t3.medium` parameter override in `deploy.sh`.
