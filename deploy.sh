#!/usr/bin/env bash
# deploy.sh  -  Provision infrastructure + deploy GitHub MCP Workshop Proxy
#
# First run creates everything from scratch. Re-runs are safe and idempotent:
# if no infra changes, CloudFormation is a no-op and only the app code is updated.
#
# Required env vars:
#   EC2_KEY    Path to your .pem key file  (e.g. ~/.ssh/workshop.pem)
#   KEY_NAME   EC2 key pair name in AWS    (e.g. "workshop")
#
# Optional env vars:
#   DOMAIN       Domain name - enables Let's Encrypt TLS (point DNS first)
#   STACK_NAME   CloudFormation stack name (default: github-mcp-proxy)
#   EC2_USER     SSH user (default: ubuntu)
#   BASE_URL     Override the public URL embedded in /register responses
#   AWS_REGION   AWS region (default: your CLI default)
#
# Examples:
#   # HTTP only - fastest, no domain needed:
#   EC2_KEY=~/.ssh/workshop.pem KEY_NAME=workshop ./deploy.sh
#
#   # With TLS - point your DNS A record at the Elastic IP first, then:
#   EC2_KEY=~/.ssh/workshop.pem KEY_NAME=workshop DOMAIN=proxy.example.com ./deploy.sh
#
#   # Code-only redeploy (infra unchanged):
#   EC2_KEY=~/.ssh/workshop.pem KEY_NAME=workshop ./deploy.sh

set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────────
EC2_KEY="${EC2_KEY:?Set EC2_KEY to your .pem file path}"
KEY_NAME="${KEY_NAME:?Set KEY_NAME to your EC2 key pair name}"
EC2_USER="${EC2_USER:-ubuntu}"
DOMAIN="${DOMAIN:-}"
STACK_NAME="${STACK_NAME:-github-mcp-proxy}"
APP_DIR="/opt/github-mcp-proxy"
SERVICE="github-mcp-proxy"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v aws >/dev/null || { echo "ERROR: aws CLI not found. Install it: https://aws.amazon.com/cli/"; exit 1; }

echo "========================================"
echo "  GitHub MCP Workshop Proxy - Deploy"
echo "========================================"
printf "  Stack    : %s\n" "$STACK_NAME"
printf "  Key pair : %s\n" "$KEY_NAME"
[[ -n "$DOMAIN" ]] && printf "  TLS      : %s (Let's Encrypt)\n" "$DOMAIN" \
                   || printf "  TLS      : none (HTTP only)\n"
echo ""

# ─── 1. Look up default VPC + a public subnet ─────────────────────────────────
echo "==> Detecting default VPC..."
VPC_ID=$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
[[ "$VPC_ID" == "None" || -z "$VPC_ID" ]] && {
  echo "ERROR: no default VPC. Set VPC_ID and SUBNET_ID env vars and add them to the deploy command."
  exit 1
}

# Prefer a subnet that auto-assigns public IPs; fall back to the first one
SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=mapPublicIpOnLaunch,Values=true" \
  --query 'Subnets[0].SubnetId' --output text)
if [[ "$SUBNET_ID" == "None" || -z "$SUBNET_ID" ]]; then
  SUBNET_ID=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[0].SubnetId' --output text)
fi
[[ "$SUBNET_ID" == "None" || -z "$SUBNET_ID" ]] && { echo "ERROR: no subnets found in $VPC_ID"; exit 1; }

printf "  VPC    : %s\n  Subnet : %s\n\n" "$VPC_ID" "$SUBNET_ID"

# ─── 2. Deploy (or update) the CloudFormation stack ───────────────────────────
echo "==> Running CloudFormation deploy..."
aws cloudformation deploy \
  --template-file "$SCRIPT_DIR/template.yaml" \
  --stack-name    "$STACK_NAME" \
  --capabilities  CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    KeyName="$KEY_NAME" \
    VpcId="$VPC_ID" \
    SubnetId="$SUBNET_ID" \
  --no-fail-on-empty-changeset

# ─── 3. Grab the Elastic IP from stack outputs ────────────────────────────────
echo "==> Reading stack outputs..."
EC2_HOST=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[?OutputKey==`PublicIP`].OutputValue' \
  --output text)
[[ -z "$EC2_HOST" ]] && { echo "ERROR: could not read PublicIP output from stack"; exit 1; }

[[ -n "$DOMAIN" ]] && BASE_URL="${BASE_URL:-https://$DOMAIN}" \
                   || BASE_URL="${BASE_URL:-http://$EC2_HOST}"

printf "  Public IP : %s\n  BASE_URL  : %s\n\n" "$EC2_HOST" "$BASE_URL"

# ─── 4. Wait for the instance to accept SSH connections ───────────────────────
SSH_OPTS="-i $EC2_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
_SSH="ssh $SSH_OPTS $EC2_USER@$EC2_HOST"
_SCP="scp -i $EC2_KEY -o StrictHostKeyChecking=no"

echo "==> Waiting for SSH..."
for i in $(seq 1 36); do
  $_SSH true 2>/dev/null && { echo "  SSH ready."; break; }
  printf "  Attempt %d/36 - retrying in 10 s...\n" "$i"
  sleep 10
done

# Wait for cloud-init (UserData package installs) to finish
echo "==> Waiting for cloud-init..."
$_SSH "cloud-init status --wait 2>/dev/null || sleep 90" || sleep 90

# ─── 5. Stage config files locally ───────────────────────────────────────────
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

# .env
cat > "$STAGING/.env" <<EOF
BASE_URL=$BASE_URL
GITHUB_MCP_UPSTREAM=http://127.0.0.1:8082
EOF

# github-mcp-server systemd unit
# Runs the official Docker image in HTTP mode with --network host so our
# proxy can reach it at localhost:8082 without any port mapping complexity.
# Port 8082 is not exposed in the security group, so it's internal only.
MCP_SERVICE="github-mcp-server"
cat > "$STAGING/$MCP_SERVICE.service" <<'EOF'
[Unit]
Description=GitHub MCP Server (HTTP)
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=root
ExecStartPre=-/usr/bin/docker rm -f github-mcp-server
ExecStart=/usr/bin/docker run --rm --name github-mcp-server \
  --network host \
  ghcr.io/github/github-mcp-server \
  http
ExecStop=/usr/bin/docker stop -t 5 github-mcp-server
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# proxy systemd unit
cat > "$STAGING/$SERVICE.service" <<EOF
[Unit]
Description=GitHub MCP Workshop Proxy
After=network.target

[Service]
Type=simple
User=$EC2_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=$APP_DIR/venv/bin/uvicorn server:app --host 127.0.0.1 --port 8000
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# nginx site config (quoted heredoc keeps $nginx_vars literal; SERVER_NAME substituted by perl)
SERVER_NAME="${DOMAIN:-_}"
cat > "$STAGING/$SERVICE.nginx" <<'NGINX'
server {
    listen 80;
    server_name __SERVER_NAME__;

    client_max_body_size 1m;

    location / {
        proxy_pass         http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
    }
}
NGINX
perl -pi -e "s/__SERVER_NAME__/$SERVER_NAME/g" "$STAGING/$SERVICE.nginx"

# ─── 6. Copy files to EC2 ─────────────────────────────────────────────────────
echo "==> Copying app files..."
$_SSH "sudo mkdir -p $APP_DIR && sudo chown $EC2_USER:$EC2_USER $APP_DIR"
$_SCP "$SCRIPT_DIR/server.py" "$SCRIPT_DIR/requirements.txt" \
  "$EC2_USER@$EC2_HOST:$APP_DIR/"
$_SCP "$STAGING/.env"                  "$EC2_USER@$EC2_HOST:$APP_DIR/.env"
$_SCP "$STAGING/$SERVICE.service"      "$EC2_USER@$EC2_HOST:/tmp/$SERVICE.service"
$_SCP "$STAGING/$MCP_SERVICE.service"  "$EC2_USER@$EC2_HOST:/tmp/$MCP_SERVICE.service"
$_SCP "$STAGING/$SERVICE.nginx"        "$EC2_USER@$EC2_HOST:/tmp/$SERVICE.nginx"

# ─── 7. Python venv + dependencies ───────────────────────────────────────────
echo "==> Setting up Python venv..."
$_SSH "python3 -m venv $APP_DIR/venv && \
  $APP_DIR/venv/bin/pip install --quiet --upgrade pip && \
  $APP_DIR/venv/bin/pip install --quiet -r $APP_DIR/requirements.txt"

# ─── 8. Pull github-mcp-server image + install its systemd service ───────────
echo "==> Pulling github-mcp-server Docker image..."
$_SSH "sudo docker pull ghcr.io/github/github-mcp-server"

echo "==> Installing github-mcp-server service..."
$_SSH "sudo mv /tmp/$MCP_SERVICE.service /etc/systemd/system/ && \
  sudo systemctl daemon-reload && \
  sudo systemctl enable $MCP_SERVICE && \
  sudo systemctl restart $MCP_SERVICE"

# ─── 9. Proxy systemd service ─────────────────────────────────────────────────
echo "==> Installing proxy service..."
$_SSH "sudo mv /tmp/$SERVICE.service /etc/systemd/system/ && \
  sudo systemctl daemon-reload && \
  sudo systemctl enable $SERVICE && \
  sudo systemctl restart $SERVICE"

# ─── 10. Nginx ────────────────────────────────────────────────────────────────
echo "==> Configuring Nginx..."
$_SSH "sudo mv /tmp/$SERVICE.nginx /etc/nginx/sites-available/$SERVICE && \
  sudo ln -sf /etc/nginx/sites-available/$SERVICE /etc/nginx/sites-enabled/$SERVICE && \
  sudo rm -f /etc/nginx/sites-enabled/default && \
  sudo nginx -t && \
  sudo systemctl reload nginx"

# ─── 11. TLS via Let's Encrypt (optional) ─────────────────────────────────────
if [[ -n "$DOMAIN" ]]; then
  echo "==> Requesting Let's Encrypt certificate for $DOMAIN..."
  echo "    (DNS must already point $DOMAIN -> $EC2_HOST)"
  $_SSH "sudo certbot --nginx -d $DOMAIN \
    --non-interactive --agree-tos \
    -m webmaster@$DOMAIN \
    --redirect"
  echo "  Certificate installed. Auto-renewal is enabled by certbot."
fi

# ─── 12. Smoke test ───────────────────────────────────────────────────────────
echo "==> Smoke test..."
sleep 3
if curl -fsS --max-time 10 "$BASE_URL/health" 2>/dev/null | grep -q '"ok"'; then
  echo "  Health check passed."
else
  echo "  Warning: $BASE_URL/health did not return ok. Service logs:"
  $_SSH "sudo journalctl -u $SERVICE -n 30 --no-pager" || true
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "  Deploy complete!"
echo "========================================"
echo ""
echo "  Endpoints:"
echo "    POST $BASE_URL/register"
echo "    POST $BASE_URL/oauth/token/{client_id}"
echo "    POST $BASE_URL/mcp"
echo "    GET  $BASE_URL/health"
echo ""
echo "  Useful commands:"
echo "    Proxy logs  : ssh -i $EC2_KEY $EC2_USER@$EC2_HOST 'sudo journalctl -u $SERVICE -f'"
echo "    MCP logs    : ssh -i $EC2_KEY $EC2_USER@$EC2_HOST 'sudo journalctl -u $MCP_SERVICE -f'"
echo "    Restart all : ssh -i $EC2_KEY $EC2_USER@$EC2_HOST 'sudo systemctl restart $SERVICE $MCP_SERVICE'"
echo "    Destroy     : aws cloudformation delete-stack --stack-name $STACK_NAME"
