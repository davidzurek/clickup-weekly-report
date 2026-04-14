#!/bin/bash
# Run this ONCE PER USER to provision that user's isolated Cloud Run job,
# Cloud Scheduler, secrets, and service account.
#
# All resources are named with the user's ClickUp user ID as a suffix so
# multiple users can coexist in the same GCP project without collisions.
#
# IAM isolation enforced:
#   - Each user's SA can only access its own two secrets (per-secret IAM)
#   - Each user's SA can only trigger its own Cloud Run job (per-job IAM)
#   - The user's Google Account can only view/execute their own job (per-job IAM)
#   - The user's Google Account can only manage their own secrets (per-secret IAM)
#   - The shared Artifact Registry image is read-only for all SAs
#
# Prerequisites:
#   - setup-project.sh has been run (APIs enabled, image pushed)
#   - gcloud is authenticated as a project owner/editor
#   - No .env required — generated automatically from example.env if absent
#
# Usage:
#   bash setup-user.sh \
#     --gcp-project-id    my-gcp-project \
#     --user-email        user@example.com \
#     --user-id           81687559 \
#     --doc-id            2gcg7-284992 \
#     --parent-page-id    2gcg7-435652 \
#     --cu-api-key        pk_xxx \
#     --llm-api-key sk-xxx
#
#   Optional overrides (defaults from example.env):
#     --workspace-id  <id>
#     --folder-id     <id>
#     --lookback-days <days>
#     --page-prefix   <prefix>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 --gcp-project-id <id> --user-email <email> --user-id <id> --doc-id <id> --parent-page-id <id> --cu-api-key <key> --llm-api-key <key>"
    echo "       Optional: --workspace-id <id> --folder-id <id> --lookback-days <days> --page-prefix <prefix>"
    exit 1
}

# Required
PROJECT_ID_ARG=""
USER_EMAIL=""
USER_ID=""
DOC_ID=""
PARENT_PAGE_ID=""
CU_API_KEY_VAL=""
LLM_API_KEY_VAL=""

# Optional overrides
WORKSPACE_ID_ARG=""
FOLDER_ID_ARG=""
LOOKBACK_DAYS_ARG=""
PAGE_PREFIX_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gcp-project-id)    PROJECT_ID_ARG="$2";         shift 2 ;;
        --user-email)        USER_EMAIL="$2";             shift 2 ;;
        --user-id)           USER_ID="$2";                shift 2 ;;
        --doc-id)            DOC_ID="$2";                 shift 2 ;;
        --parent-page-id)    PARENT_PAGE_ID="$2";         shift 2 ;;
        --cu-api-key)        CU_API_KEY_VAL="$2";         shift 2 ;;
        --llm-api-key) LLM_API_KEY_VAL="$2";  shift 2 ;;
        --workspace-id)      WORKSPACE_ID_ARG="$2";       shift 2 ;;
        --folder-id)         FOLDER_ID_ARG="$2";          shift 2 ;;
        --lookback-days)     LOOKBACK_DAYS_ARG="$2";      shift 2 ;;
        --page-prefix)       PAGE_PREFIX_ARG="$2";        shift 2 ;;
        *) echo "Unknown flag: $1"; usage ;;
    esac
done

if [[ -z "$PROJECT_ID_ARG" || -z "$USER_EMAIL" || -z "$USER_ID" || -z "$DOC_ID" || -z "$PARENT_PAGE_ID" || -z "$CU_API_KEY_VAL" || -z "$LLM_API_KEY_VAL" ]]; then
    echo "Error: missing required flags."
    usage
fi

# ─── POPULATE .env FROM example.env IF NOT PRESENT ───────────────────────────
# This means the script works fresh out of a git clone with no manual prep.
if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    echo "==> .env not found, generating from example.env"
    cp "$SCRIPT_DIR/example.env" "$SCRIPT_DIR/.env"
fi

# Apply project-level overrides into .env via sed so sourcing picks them up
sed -i "s|^PROJECT_ID=.*|PROJECT_ID=\"$PROJECT_ID_ARG\"|" "$SCRIPT_DIR/.env"
[[ -n "$WORKSPACE_ID_ARG"  ]] && sed -i "s|^WORKSPACE_ID=.*|WORKSPACE_ID=\"$WORKSPACE_ID_ARG\"|"   "$SCRIPT_DIR/.env"
[[ -n "$FOLDER_ID_ARG"     ]] && sed -i "s|^FOLDER_ID=.*|FOLDER_ID=\"$FOLDER_ID_ARG\"|"             "$SCRIPT_DIR/.env"
[[ -n "$LOOKBACK_DAYS_ARG" ]] && sed -i "s|^LOOKBACK_DAYS=.*|LOOKBACK_DAYS=\"$LOOKBACK_DAYS_ARG\"|" "$SCRIPT_DIR/.env"

set -a && source "$SCRIPT_DIR/.env" && set +a

# Apply remaining overrides that don't live in .env
PAGE_PREFIX="${PAGE_PREFIX_ARG:-${PAGE_PREFIX:-CW}}"

# ─── PER-USER RESOURCE NAMES ─────────────────────────────────────────────────
SA_NAME="sa-cr-job-${USER_ID}"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
JOB_NAME="clickup-weekly-report-job-${USER_ID}"
SCHEDULER_NAME="clickup-weekly-report-schedule-${USER_ID}"
CU_SECRET_NAME="cu-api-key-${USER_ID}"
LLM_SECRET_NAME="llm-api-key-${USER_ID}"
IMAGE_URI="$LOCATION-docker.pkg.dev/$PROJECT_ID/$REPOSITORY/$IMAGE_NAME:latest"

echo "==> Setting GCP project to $PROJECT_ID"
gcloud config set project "$PROJECT_ID"

echo "==> Setting up resources for $USER_EMAIL (ClickUp user ID: $USER_ID)"

# ─── SERVICE ACCOUNT ─────────────────────────────────────────────────────────
echo "==> Creating service account $SA_NAME"
gcloud iam service-accounts create "$SA_NAME" \
    --description="Cloud Run job SA for ClickUp user ${USER_ID}" \
    --display-name="ClickUp Report - ${USER_ID}"

# ─── SECRETS ─────────────────────────────────────────────────────────────────
echo "==> Creating secret $CU_SECRET_NAME"
gcloud secrets create "$CU_SECRET_NAME" \
    --locations="$LOCATION" \
    --replication-policy=user-managed \
    --data-file=<(echo -n "$CU_API_KEY_VAL")

echo "==> Creating secret $LLM_SECRET_NAME"
gcloud secrets create "$LLM_SECRET_NAME" \
    --locations="$LOCATION" \
    --replication-policy=user-managed \
    --data-file=<(echo -n "$LLM_API_KEY_VAL")

# ─── SECRET IAM: SA can read its own secrets only ────────────────────────────
echo "==> Granting SA read access to its own secrets"
gcloud secrets add-iam-policy-binding "$CU_SECRET_NAME" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/secretmanager.secretAccessor"

gcloud secrets add-iam-policy-binding "$LLM_SECRET_NAME" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/secretmanager.secretAccessor"

# ─── SECRET IAM: User can manage their own secrets only ──────────────────────
# roles/secretmanager.secretVersionManager allows adding new versions (key rotation)
# and reading the current value — scoped to these two secrets only.
echo "==> Granting $USER_EMAIL access to their own secrets"
gcloud secrets add-iam-policy-binding "$CU_SECRET_NAME" \
    --member="user:${USER_EMAIL}" \
    --role="roles/secretmanager.secretVersionManager"

gcloud secrets add-iam-policy-binding "$LLM_SECRET_NAME" \
    --member="user:${USER_EMAIL}" \
    --role="roles/secretmanager.secretVersionManager"

# ─── ARTIFACT REGISTRY: SA can pull the shared image ─────────────────────────
echo "==> Granting SA read access to the shared Artifact Registry repository"
gcloud artifacts repositories add-iam-policy-binding "$REPOSITORY" \
    --location="$LOCATION" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/artifactregistry.reader"

# ─── CLOUD RUN JOB ───────────────────────────────────────────────────────────
echo "==> Deploying Cloud Run job $JOB_NAME"
gcloud run jobs deploy "$JOB_NAME" \
    --image "$IMAGE_URI" \
    --region "$LOCATION" \
    --max-retries 1 \
    --task-timeout 600s \
    --service-account "$SA_EMAIL" \
    --memory 512Mi \
    --set-env-vars "WORKSPACE_ID=${WORKSPACE_ID},FOLDER_ID=${FOLDER_ID},USER_ID=${USER_ID},DOC_ID=${DOC_ID},PARENT_PAGE_ID=${PARENT_PAGE_ID},LOOKBACK_DAYS=${LOOKBACK_DAYS},PAGE_PREFIX=${PAGE_PREFIX}" \
    --set-secrets "CU_API_KEY=${CU_SECRET_NAME}:latest,LLM_API_KEY=${LLM_SECRET_NAME}:latest"

# ─── JOB IAM: SA can trigger its own job (required by Cloud Scheduler) ───────
# Scoped to this job only — SA cannot see or touch any other Cloud Run job.
echo "==> Granting SA permission to trigger its own job"
gcloud run jobs add-iam-policy-binding "$JOB_NAME" \
    --region="$LOCATION" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/run.developer"

# ─── JOB IAM: User can view and manually trigger their own job only ──────────
echo "==> Granting $USER_EMAIL access to their own job"
gcloud run jobs add-iam-policy-binding "$JOB_NAME" \
    --region="$LOCATION" \
    --member="user:${USER_EMAIL}" \
    --role="roles/run.developer"

# ─── CLOUD SCHEDULER ─────────────────────────────────────────────────────────
echo "==> Creating Cloud Scheduler job $SCHEDULER_NAME (every Thursday 12:00 Berlin)"
gcloud scheduler jobs create http "$SCHEDULER_NAME" \
    --schedule="00 12 * * 4" \
    --location="$LOCATION" \
    --time-zone="Europe/Berlin" \
    --http-method=POST \
    --message-body='{}' \
    --uri="https://run.googleapis.com/v2/projects/${PROJECT_ID}/locations/${LOCATION}/jobs/${JOB_NAME}:run" \
    --oauth-service-account-email="$SA_EMAIL"

# ─── SUMMARY ─────────────────────────────────────────────────────────────────
echo ""
echo "Done. Resources created for $USER_EMAIL:"
echo "  Service account : $SA_EMAIL"
echo "  Secrets         : $CU_SECRET_NAME, $LLM_SECRET_NAME"
echo "  Cloud Run job   : $JOB_NAME"
echo "  Scheduler       : $SCHEDULER_NAME (every Thursday 12:00 Berlin)"
echo ""
echo "The user can manually trigger their job with:"
echo "  gcloud run jobs execute $JOB_NAME --region $LOCATION"
echo ""
echo "The user can rotate their ClickUp API key with:"
echo "  echo -n 'new-key' | gcloud secrets versions add $CU_SECRET_NAME --data-file=-"
echo ""
echo "The user can rotate their LLM API key with:"
echo "  echo -n 'new-key' | gcloud secrets versions add $LLM_SECRET_NAME --data-file=-"
