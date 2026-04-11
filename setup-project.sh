#!/bin/bash
# Run this ONCE as the admin to initialise shared project infrastructure.
# It enables GCP APIs, creates the Artifact Registry repo, and builds/pushes
# the Docker image that every user's Cloud Run job will share.
#
# Prerequisites:
#   - .env is populated (copy example.env and fill in PROJECT_ID, LOCATION, etc.)
#   - Docker is running locally
#   - gcloud is authenticated as a project owner/editor
#
# Usage:
#   bash setup-project.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    echo "Error: .env not found. Copy example.env to .env and fill in your values."
    exit 1
fi

set -a && source "$SCRIPT_DIR/.env" && set +a

echo "==> Setting GCP project to $PROJECT_ID"
gcloud config set project "$PROJECT_ID"

echo "==> Enabling required GCP APIs"
gcloud services enable \
    secretmanager.googleapis.com \
    run.googleapis.com \
    artifactregistry.googleapis.com \
    cloudscheduler.googleapis.com

echo "==> Creating Artifact Registry repository '$REPOSITORY' (skipped if it already exists)"
if gcloud artifacts repositories describe "$REPOSITORY" --location="$LOCATION" &>/dev/null; then
    echo "    Repository already exists, skipping."
else
    gcloud artifacts repositories create "$REPOSITORY" \
        --repository-format=docker \
        --location="$LOCATION" \
        --description="Docker repository for ClickUp weekly report"
fi

echo "==> Authenticating Docker with Artifact Registry"
gcloud auth configure-docker "$LOCATION-docker.pkg.dev" --quiet

IMAGE_URI="$LOCATION-docker.pkg.dev/$PROJECT_ID/$REPOSITORY/$IMAGE_NAME:latest"

echo "==> Building Docker image"
docker build --platform linux/amd64 -t "$IMAGE_URI" "$SCRIPT_DIR"

echo "==> Pushing image to Artifact Registry"
docker push "$IMAGE_URI"

echo ""
echo "Project setup complete."
echo "Shared image: $IMAGE_URI"
echo ""
echo "Next step: run setup-user.sh for each user."
echo "  bash setup-user.sh \\"
echo "    --user-email  user@example.com \\"
echo "    --user-id     <clickup-user-id> \\"
echo "    --doc-id      <clickup-doc-id> \\"
echo "    --parent-page-id <page-id> \\"
echo "    --cu-api-key  pk_xxx \\"
echo "    --anthropic-api-key sk-ant-xxx"
