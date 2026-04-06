#!/bin/bash

# SOURCE ENV VARIABLES
source .env .env.secrets

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
    --role="roles/run.invoker"

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


# # CREATE SCHEDULE FOR CLOUD RUN JOB
# gcloud scheduler jobs create pubsub clickup-weekly-report-schedule \
#     --schedule="00 12 * * 4" \
#     --time-zone="Europe/Berlin" \
#     --topic=projects/$PROJECT_ID/topics/cloud-run-jobs \
#     --message-body='{"jobName":"projects/'$PROJECT_ID'/locations/'$LOCATION'/jobs/'$JOB_NAME'"}'
