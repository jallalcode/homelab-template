#!/bin/bash
set -euo pipefail

SERVICE=${1:?"Usage: deploy.sh <service> [project-id]"}
PROJECT_ID=${2:-}

SERVICE_DIR="/opt/homelab/services/$SERVICE"

if [ ! -d "$SERVICE_DIR" ]; then
  echo "Error: service directory $SERVICE_DIR does not exist"
  exit 1
fi

cd "$SERVICE_DIR"

# Pull secrets from Infisical if a project ID is provided
if [ -n "$PROJECT_ID" ]; then
  echo "Pulling secrets from Infisical for $SERVICE..."

  # ──────────────────────────────────────────────────────────────
  # CONFIGURE THIS: Set your Infisical instance URL
  # For Infisical Cloud: https://app.infisical.com/api
  # For self-hosted:     https://secrets.yourdomain.com/api
  # ──────────────────────────────────────────────────────────────
  export INFISICAL_API_URL="${INFISICAL_API_URL:-https://secrets.yourdomain.com/api}"

  INFISICAL_TOKEN=$(infisical login \
    --method=universal-auth \
    --client-id="${INFISICAL_CLIENT_ID:?INFISICAL_CLIENT_ID must be set}" \
    --client-secret="${INFISICAL_CLIENT_SECRET:?INFISICAL_CLIENT_SECRET must be set}" \
    --silent --plain)

  export INFISICAL_TOKEN

  infisical export \
    --projectId="$PROJECT_ID" \
    --env=prod \
    --format=dotenv > .env

  chmod 600 .env
  echo "Secrets written to .env"
else
  echo "No Infisical project ID — skipping secret injection for $SERVICE"
fi

echo "Pulling latest images for $SERVICE..."
docker compose pull

echo "Starting $SERVICE..."
docker compose up -d --remove-orphans

echo "Deploy of $SERVICE complete"
docker compose ps