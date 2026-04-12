#!/bin/bash
# Full admin setup: enables GCP APIs, creates the Artifact Registry repo,
# builds and pushes the shared Docker image, sets up service accounts and
# IAM, stores config in Secret Manager, and deploys the provision-user
# Cloud Function.
#
# Run this once as a project owner/editor. Re-run whenever the Docker image
# or Cloud Function code changes, or to rotate the provisioning key.
#
# Prerequisites:
#   - .env is populated (copy example.env and fill in all values)
#   - Docker is running locally
#   - gcloud is authenticated as a project owner/editor
#
# Usage:
#   bash deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    echo "Error: .env not found. Copy example.env and fill in your values."
    exit 1
fi

set -a && source "$SCRIPT_DIR/.env" && set +a

PROVISIONER_SA_NAME="sa-provisioner"
PROVISIONER_SA_EMAIL="${PROVISIONER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
BUILD_SA_NAME="sa-cloudbuild"
BUILD_SA_EMAIL="${BUILD_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
FUNCTION_NAME="provision-user"
IMAGE_URI="$LOCATION-docker.pkg.dev/$PROJECT_ID/$REPOSITORY/$IMAGE_NAME:latest"

echo "==> Setting GCP project to $PROJECT_ID"
gcloud config set project "$PROJECT_ID"

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")

# ─── ENABLE REQUIRED APIS ─────────────────────────────────────────────────────
echo "==> Enabling required GCP APIs"
gcloud services enable \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com \
    cloudfunctions.googleapis.com \
    cloudscheduler.googleapis.com \
    iam.googleapis.com \
    run.googleapis.com \
    secretmanager.googleapis.com

# ─── ARTIFACT REGISTRY ────────────────────────────────────────────────────────
if gcloud artifacts repositories describe "$REPOSITORY" --location="$LOCATION" &>/dev/null; then
    echo "==> Artifact Registry repository '$REPOSITORY' already exists, skipping"
else
    echo "==> Creating Artifact Registry repository '$REPOSITORY'"
    gcloud artifacts repositories create "$REPOSITORY" \
        --repository-format=docker \
        --location="$LOCATION" \
        --description="Docker repository for ClickUp weekly report"
fi

# ─── DOCKER IMAGE ─────────────────────────────────────────────────────────────
echo "==> Authenticating Docker with Artifact Registry"
gcloud auth configure-docker "$LOCATION-docker.pkg.dev" --quiet

echo "==> Building Docker image"
docker build --platform linux/amd64 -t "$IMAGE_URI" "$SCRIPT_DIR"

echo "==> Pushing image to Artifact Registry"
docker push "$IMAGE_URI"

# ─── DEDICATED CLOUD BUILD SERVICE ACCOUNT ────────────────────────────────────
# Cloud Functions gen2 uses Cloud Build internally to build the container image.
# We use a dedicated SA instead of the default Compute Engine SA to keep
# build permissions isolated and avoid granting broad roles to the default SA.
if gcloud iam service-accounts describe "$BUILD_SA_EMAIL" &>/dev/null; then
    echo "==> Cloud Build service account $BUILD_SA_NAME already exists, skipping"
else
    echo "==> Creating dedicated Cloud Build service account"
    gcloud iam service-accounts create "$BUILD_SA_NAME" \
        --description="Service account for Cloud Build (Cloud Functions gen2 builds)" \
        --display-name="ClickUp Cloud Build"

    echo "==> Waiting for $BUILD_SA_NAME to propagate..."
    until gcloud iam service-accounts describe "$BUILD_SA_EMAIL" &>/dev/null; do
        sleep 2
    done
    echo "    Service account ready"
fi

echo "==> Granting Cloud Build builder role to $BUILD_SA_NAME"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${BUILD_SA_EMAIL}" \
    --role="roles/cloudbuild.builds.builder"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${BUILD_SA_EMAIL}" \
    --role="roles/logging.logWriter"

GCF_SOURCES_BUCKET="gcf-v2-sources-${PROJECT_NUMBER}-${LOCATION}"

# ─── PROVISIONER SERVICE ACCOUNT ──────────────────────────────────────────────
if gcloud iam service-accounts describe "$PROVISIONER_SA_EMAIL" &>/dev/null; then
    echo "==> Service account $PROVISIONER_SA_NAME already exists, skipping"
else
    echo "==> Creating provisioner service account"
    gcloud iam service-accounts create "$PROVISIONER_SA_NAME" \
        --description="Service account for the provision_user Cloud Function" \
        --display-name="ClickUp Provisioner"

    echo "==> Waiting for $PROVISIONER_SA_NAME to propagate..."
    until gcloud iam service-accounts describe "$PROVISIONER_SA_EMAIL" &>/dev/null; do
        sleep 2
    done
    echo "    Service account ready"
fi

# ─── GRANT PROVISIONER SA THE PERMISSIONS IT NEEDS ────────────────────────────
# These are intentionally broad at the project level — the provisioner SA is
# admin-controlled and only reachable via the provisioning key check in the function.
echo "==> Granting provisioner SA required roles"

for role in \
    roles/iam.serviceAccountAdmin \
    roles/iam.serviceAccountUser \
    roles/secretmanager.admin \
    roles/artifactregistry.admin \
    roles/run.admin \
    roles/cloudscheduler.admin \
    roles/logging.admin; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${PROVISIONER_SA_EMAIL}" \
        --role="$role"
done

# ─── PROVISION CONFIG SECRET ───────────────────────────────────────────────────
# Bundling everything into one JSON secret avoids org policies that block
# certain env var name patterns (e.g. *_KEY, *_TOKEN) on Cloud Run.
if gcloud secrets describe "provision-config" &>/dev/null; then
    echo "==> Secret provision-config already exists — adding a new version with fresh config"
    PROVISIONING_KEY=$(gcloud secrets versions access latest --secret="provision-config" | jq -r '.provisioning_key')
    echo "    Re-using existing provisioning key"
else
    echo "==> Generating provisioning key and storing config secret"
    PROVISIONING_KEY=$(openssl rand -hex 32)
fi

PROVISION_CONFIG=$(jq -n \
    --arg project_id       "$PROJECT_ID" \
    --arg location         "$LOCATION" \
    --arg repository       "$REPOSITORY" \
    --arg image_name       "$IMAGE_NAME" \
    --arg workspace_id     "$WORKSPACE_ID" \
    --arg folder_id        "$FOLDER_ID" \
    --arg lookback_days    "$LOOKBACK_DAYS" \
    --arg page_prefix      "$PAGE_PREFIX" \
    --arg provisioning_key "$PROVISIONING_KEY" \
    '{
        project_id:       $project_id,
        location:         $location,
        repository:       $repository,
        image_name:       $image_name,
        workspace_id:     $workspace_id,
        folder_id:        $folder_id,
        lookback_days:    $lookback_days,
        page_prefix:      $page_prefix,
        provisioning_key: $provisioning_key
    }')

if gcloud secrets describe "provision-config" &>/dev/null; then
    echo -n "$PROVISION_CONFIG" | gcloud secrets versions add "provision-config" --data-file=-
else
    gcloud secrets create "provision-config" \
        --locations="$LOCATION" \
        --replication-policy=user-managed \
        --data-file=<(echo -n "$PROVISION_CONFIG")
fi

echo "    Config stored in Secret Manager as 'provision-config'"

# ─── DEPLOY CLOUD FUNCTION ────────────────────────────────────────────────────
# No --set-env-vars at all — all config comes in via the single JSON secret.
#
# GCP creates the gcf-v2-sources bucket lazily on the first deploy to a region.
# We can only grant the build SA access to it after it exists, so:
#   1. If the bucket already exists — grant now, then deploy normally.
#   2. If the bucket does not exist — run a bootstrap deploy (it will fail at
#      the Cloud Build step, but that is enough to cause GCP to create the
#      bucket), then grant access, then do the real deploy.

_deploy_function() {
    gcloud functions deploy "$FUNCTION_NAME" \
        --gen2 \
        --runtime=python312 \
        --region="$LOCATION" \
        --source="$SCRIPT_DIR/provision" \
        --entry-point=provision_user \
        --trigger-http \
        --timeout=300 \
        --min-instances=0 \
        --max-instances=10 \
        --allow-unauthenticated \
        --service-account="$PROVISIONER_SA_EMAIL" \
        --build-service-account="projects/${PROJECT_ID}/serviceAccounts/${BUILD_SA_EMAIL}" \
        --set-secrets "PROVISION_CONFIG=provision-config:latest"
}

_grant_gcf_bucket_access() {
    echo "==> Granting storage access on $GCF_SOURCES_BUCKET to $BUILD_SA_NAME"
    gcloud storage buckets add-iam-policy-binding "gs://${GCF_SOURCES_BUCKET}" \
        --member="serviceAccount:${BUILD_SA_EMAIL}" \
        --role="roles/storage.objectAdmin"
}

if gcloud storage buckets describe "gs://${GCF_SOURCES_BUCKET}" &>/dev/null; then
    _grant_gcf_bucket_access
    echo "==> Deploying Cloud Function $FUNCTION_NAME"
    _deploy_function
else
    echo "==> Bucket $GCF_SOURCES_BUCKET does not exist yet"
    echo "    Running bootstrap deploy so GCP creates the bucket (expected to fail)..."
    _deploy_function || true
    _grant_gcf_bucket_access
    echo "==> Deploying Cloud Function $FUNCTION_NAME"
    _deploy_function
fi

FUNCTION_URL=$(gcloud functions describe "$FUNCTION_NAME" \
    --region="$LOCATION" \
    --format="value(serviceConfig.uri)")

echo ""
echo "Setup complete."
echo "  Docker image  : $IMAGE_URI"
echo "  Function URL  : $FUNCTION_URL"
echo ""
echo "Share the following with your users:"
echo "  Provisioning key : $PROVISIONING_KEY"
echo "  Setup page URL   : $FUNCTION_URL"
echo ""
echo "Users open the URL in their browser, fill in the form, and click Submit."
echo ""
echo "To rotate the provisioning key later:"
echo "  NEW_KEY=\$(openssl rand -hex 32)"
echo "  gcloud secrets versions access latest --secret=provision-config \\"
echo "    | jq --arg k \"\$NEW_KEY\" '.provisioning_key = \$k' \\"
echo "    | gcloud secrets versions add provision-config --data-file=-"
echo "  echo \"New provisioning key: \$NEW_KEY\""
