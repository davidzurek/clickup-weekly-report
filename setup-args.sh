#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: $0 --user-id <id> --doc-id <id> --parent-page-id <id> --cu-api-key <key> --anthropic-api-key <key>"
    echo "       Optional: --gcp-project-id <id> --workspace-id <id> --folder-id <id> --lookback-days <days>"
    exit 1
}

# required
USER_ID=""
DOC_ID=""
PARENT_PAGE_ID=""
CU_API_KEY_ARG=""
ANTHROPIC_API_KEY_ARG=""

# optional (defaults come from example.env)
PROJECT_ID_ARG=""
WORKSPACE_ID_ARG=""
FOLDER_ID_ARG=""
LOOKBACK_DAYS_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gcp-project-id)     PROJECT_ID_ARG="$2";        shift 2 ;;
        --workspace-id)       WORKSPACE_ID_ARG="$2";      shift 2 ;;
        --folder-id)          FOLDER_ID_ARG="$2";         shift 2 ;;
        --user-id)            USER_ID="$2";               shift 2 ;;
        --doc-id)             DOC_ID="$2";                shift 2 ;;
        --parent-page-id)     PARENT_PAGE_ID="$2";        shift 2 ;;
        --lookback-days)      LOOKBACK_DAYS_ARG="$2";     shift 2 ;;
        --cu-api-key)         CU_API_KEY_ARG="$2";        shift 2 ;;
        --anthropic-api-key)  ANTHROPIC_API_KEY_ARG="$2"; shift 2 ;;
        *) echo "Unknown flag: $1"; usage ;;
    esac
done

if [[ -z "$USER_ID" || -z "$DOC_ID" || -z "$PARENT_PAGE_ID" || -z "$CU_API_KEY_ARG" || -z "$ANTHROPIC_API_KEY_ARG" ]]; then
    echo "Error: all flags are required."
    usage
fi

# POPULATE .env FILES FROM EXAMPLES
cp example.env .env
cp example.env.secrets .env.secrets

# optional overrides
[[ -n "$PROJECT_ID_ARG"    ]] && sed -i "s|^PROJECT_ID=.*|PROJECT_ID=\"$PROJECT_ID_ARG\"|" .env
[[ -n "$WORKSPACE_ID_ARG"  ]] && sed -i "s|^WORKSPACE_ID=.*|WORKSPACE_ID=\"$WORKSPACE_ID_ARG\"|" .env
[[ -n "$FOLDER_ID_ARG"     ]] && sed -i "s|^FOLDER_ID=.*|FOLDER_ID=\"$FOLDER_ID_ARG\"|" .env
[[ -n "$LOOKBACK_DAYS_ARG" ]] && sed -i "s|^LOOKBACK_DAYS=.*|LOOKBACK_DAYS=\"$LOOKBACK_DAYS_ARG\"|" .env

# required substitutions
sed -i "s|my-user-id|$USER_ID|" .env
sed -i "s|my-doc-id|$DOC_ID|" .env
sed -i "s|my-parent-page-id|$PARENT_PAGE_ID|" .env
sed -i "s|my-cu-api-key|$CU_API_KEY_ARG|" .env.secrets
sed -i "s|my-anthropic-api-key|$ANTHROPIC_API_KEY_ARG|" .env.secrets

# SOURCE ENV VARIABLES
source .env
source .env.secrets

# Set project id for gcloud commands
gcloud config set project $PROJECT_ID

# ENABLE REQUIRED SERVICES
gcloud services enable secretmanager.googleapis.com
gcloud services enable run.googleapis.com
gcloud services enable artifactregistry.googleapis.com

# CREATE SECRET FOR API KEYS
gcloud secrets create cu-api-key --locations=$LOCATION --replication-policy=user-managed --data-file=<(echo -n "$CU_API_KEY")
gcloud secrets create anthropic-api-key --locations=$LOCATION --replication-policy=user-managed --data-file=<(echo -n "$ANTHROPIC_API_KEY")

# CREATE SERVICE ACCOUNT
gcloud iam service-accounts create sa-cr-job \
    --description="Service account for Cloud Run job" \
    --display-name="Cloud Run Job SA"

# GRANT ROLES TO SERVICE ACCOUNT
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:sa-cr-job@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/run.developer"

# GRANT ACCESS TO SECRETS
gcloud secrets add-iam-policy-binding cu-api-key \
    --member="serviceAccount:sa-cr-job@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"

gcloud secrets add-iam-policy-binding anthropic-api-key \
    --member="serviceAccount:sa-cr-job@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"

# CREATE ARTIFACT REGISTRY REPOSITORY
gcloud artifacts repositories create $REPOSITORY --repository-format=docker --location=$LOCATION --description="Docker repository for ClickUp weekly report"

# CREATE DOCKER IMAGE & PUSH TO GOOGLE ARTIFACT REGISTRY
docker build --platform linux/amd64 -t $LOCATION-docker.pkg.dev/$PROJECT_ID/$REPOSITORY/$IMAGE_NAME:latest .
docker push $LOCATION-docker.pkg.dev/$PROJECT_ID/$REPOSITORY/$IMAGE_NAME:latest

# CREATE CLOUD RUN JOB
gcloud run jobs deploy $JOB_NAME \
    --image $LOCATION-docker.pkg.dev/$PROJECT_ID/$REPOSITORY/$IMAGE_NAME:latest \
    --region $LOCATION \
    --max-retries 1 \
    --task-timeout 600s \
    --service-account sa-cr-job@$PROJECT_ID.iam.gserviceaccount.com \
    --memory 512Mi \
    --env-vars-file .env \
    --set-secrets CU_API_KEY=cu-api-key:latest,ANTHROPIC_API_KEY=anthropic-api-key:latest

# CREATE SCHEDULE FOR CLOUD RUN JOB
gcloud scheduler jobs create http clickup-weekly-report-schedule \
    --schedule="00 12 * * 4" \
    --location=$LOCATION \
    --time-zone="Europe/Berlin" \
    --http-method=POST \
    --message-body='{}' \
    --uri="https://run.googleapis.com/v2/projects/$PROJECT_ID/locations/$LOCATION/jobs/$JOB_NAME:run" \
    --oauth-service-account-email=sa-cr-job@$PROJECT_ID.iam.gserviceaccount.com
