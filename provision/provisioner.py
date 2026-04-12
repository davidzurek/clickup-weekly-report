"""GCP provisioning logic for per-user Cloud Run jobs and associated resources."""

from __future__ import annotations

import logging

from google.api_core.exceptions import AlreadyExists, NotFound
from google.cloud import artifactregistry_v1, iam_admin_v1, run_v2, scheduler_v1, secretmanager_v1
from google.cloud.logging_v2.services.config_service_v2 import ConfigServiceV2Client as _LoggingConfigClient
from google.cloud.logging_v2.types import LogView as _LogView
from google.iam.v1 import iam_policy_pb2, policy_pb2
from google.protobuf import duration_pb2

from config import cfg, JOB_MAX_RETRIES, JOB_MEMORY, JOB_TIMEOUT_S, SCHEDULE, TIMEZONE
from models import ResourceNames, UserRequest

logger = logging.getLogger(__name__)

# ─── GCP CLIENTS (module-level for warm-start reuse) ─────────────────────────

_iam_client       = iam_admin_v1.IAMClient()
_secret_client    = secretmanager_v1.SecretManagerServiceClient()
_ar_client        = artifactregistry_v1.ArtifactRegistryClient()
_run_client       = run_v2.JobsClient()
_scheduler_client = scheduler_v1.CloudSchedulerClient()


# ─── ORCHESTRATOR ─────────────────────────────────────────────────────────────

def provision(req: UserRequest, names: ResourceNames) -> None:
    """Create or update all GCP resources for a single user."""
    _ensure_service_account(names.sa_name, req.user_id)
    _upsert_secret(names.cu_secret_name, req.cu_api_key.encode(), names.sa_email, req.user_email)
    _upsert_secret(names.anthropic_secret_name, req.anthropic_api_key.encode(), names.sa_email, req.user_email)
    _grant_artifact_registry_reader(names.sa_email)
    _upsert_cloud_run_job(req, names)
    _set_job_iam(names.job_name, names.sa_email, req.user_email)
    _upsert_scheduler(names.scheduler_name, names.job_name, names.sa_email)
    _upsert_log_view(names.job_name, req.user_id, req.user_email)
    if req.execute_immediately:
        _execute_job(names.job_name)


def job_console_url(names: ResourceNames) -> str:
    return (
        f"https://console.cloud.google.com/run/jobs/details/{cfg.location}"
        f"/{names.job_name}/executions?project={cfg.project_id}"
    )


# ─── SERVICE ACCOUNT ─────────────────────────────────────────────────────────

def _ensure_service_account(sa_name: str, user_id: str) -> None:
    sa_path = f"projects/{cfg.project_id}/serviceAccounts/{sa_name}@{cfg.project_id}.iam.gserviceaccount.com"
    try:
        _iam_client.get_service_account(request=iam_admin_v1.GetServiceAccountRequest(name=sa_path))
        logger.info("Service account %s already exists, skipping", sa_name)
    except NotFound:
        _iam_client.create_service_account(
            request=iam_admin_v1.CreateServiceAccountRequest(
                name=f"projects/{cfg.project_id}",
                account_id=sa_name,
                service_account=iam_admin_v1.ServiceAccount(
                    display_name=f"ClickUp Report - {user_id}",
                    description=f"Cloud Run job SA for ClickUp user {user_id}",
                ),
            )
        )
        logger.info("Created service account %s", sa_name)


# ─── SECRETS ─────────────────────────────────────────────────────────────────

def _upsert_secret(secret_name: str, secret_value: bytes, sa_email: str, user_email: str) -> None:
    parent      = f"projects/{cfg.project_id}"
    secret_path = f"{parent}/secrets/{secret_name}"

    try:
        _secret_client.get_secret(name=secret_path)
        logger.info("Secret %s already exists, adding new version", secret_name)
    except NotFound:
        _secret_client.create_secret(
            parent=parent,
            secret_id=secret_name,
            secret=secretmanager_v1.Secret(
                replication=secretmanager_v1.Replication(
                    user_managed=secretmanager_v1.Replication.UserManaged(
                        replicas=[secretmanager_v1.Replication.UserManaged.Replica(location=cfg.location)]
                    )
                )
            ),
        )
        logger.info("Created secret %s", secret_name)

    # Always add a new version — idempotent if value unchanged, updates if rotated.
    _secret_client.add_secret_version(
        parent=secret_path,
        payload=secretmanager_v1.SecretPayload(data=secret_value),
    )

    # set_iam_policy is a full replace, so this is always idempotent.
    _secret_client.set_iam_policy(
        request=iam_policy_pb2.SetIamPolicyRequest(
            resource=secret_path,
            policy=policy_pb2.Policy(
                bindings=[
                    policy_pb2.Binding(
                        role="roles/secretmanager.secretAccessor",
                        members=[f"serviceAccount:{sa_email}"],
                    ),
                    policy_pb2.Binding(
                        role="roles/secretmanager.secretVersionManager",
                        members=[f"user:{user_email}"],
                    ),
                ]
            ),
        )
    )
    logger.info("Upserted secret %s", secret_name)


# ─── ARTIFACT REGISTRY ───────────────────────────────────────────────────────

def _grant_artifact_registry_reader(sa_email: str) -> None:
    repo_path = f"projects/{cfg.project_id}/locations/{cfg.location}/repositories/{cfg.repository}"
    member    = f"serviceAccount:{sa_email}"

    # Read-modify-write to avoid overwriting bindings for other service accounts.
    policy = _ar_client.get_iam_policy(request=iam_policy_pb2.GetIamPolicyRequest(resource=repo_path))
    reader = next((b for b in policy.bindings if b.role == "roles/artifactregistry.reader"), None)
    if reader:
        if member not in reader.members:
            reader.members.append(member)
    else:
        policy.bindings.append(policy_pb2.Binding(role="roles/artifactregistry.reader", members=[member]))

    _ar_client.set_iam_policy(request=iam_policy_pb2.SetIamPolicyRequest(resource=repo_path, policy=policy))
    logger.info("Granted artifactregistry.reader to %s", sa_email)


# ─── CLOUD RUN JOB ───────────────────────────────────────────────────────────

def _build_run_job(req: UserRequest, names: ResourceNames) -> run_v2.Job:
    """Pure function — builds the Cloud Run Job proto from request + resource names."""
    env_plain = [
        run_v2.EnvVar(name="WORKSPACE_ID",   value=req.workspace_id),
        run_v2.EnvVar(name="FOLDER_ID",      value=req.folder_id),
        run_v2.EnvVar(name="USER_ID",        value=req.user_id),
        run_v2.EnvVar(name="DOC_ID",         value=req.doc_id),
        run_v2.EnvVar(name="PARENT_PAGE_ID", value=req.parent_page_id),
        run_v2.EnvVar(name="LOOKBACK_DAYS",  value=req.lookback_days),
        run_v2.EnvVar(name="PAGE_PREFIX",    value=req.page_prefix),
    ]
    env_secrets = [
        run_v2.EnvVar(
            name="CU_API_KEY",
            value_source=run_v2.EnvVarSource(
                secret_key_ref=run_v2.SecretKeySelector(
                    secret=f"projects/{cfg.project_id}/secrets/{names.cu_secret_name}",
                    version="latest",
                )
            ),
        ),
        run_v2.EnvVar(
            name="ANTHROPIC_API_KEY",
            value_source=run_v2.EnvVarSource(
                secret_key_ref=run_v2.SecretKeySelector(
                    secret=f"projects/{cfg.project_id}/secrets/{names.anthropic_secret_name}",
                    version="latest",
                )
            ),
        ),
    ]
    return run_v2.Job(
        template=run_v2.ExecutionTemplate(
            template=run_v2.TaskTemplate(
                containers=[
                    run_v2.Container(
                        image=cfg.image_uri,
                        env=env_plain + env_secrets,
                        resources=run_v2.ResourceRequirements(limits={"memory": JOB_MEMORY}),
                    )
                ],
                service_account=names.sa_email,
                max_retries=JOB_MAX_RETRIES,
                timeout=duration_pb2.Duration(seconds=JOB_TIMEOUT_S),
            )
        )
    )


def _upsert_cloud_run_job(req: UserRequest, names: ResourceNames) -> None:
    job = _build_run_job(req, names)

    try:
        _run_client.create_job(parent=cfg.parent, job=job, job_id=names.job_name).result()
        logger.info("Created Cloud Run job %s", names.job_name)
    except AlreadyExists:
        job.name = f"{cfg.parent}/jobs/{names.job_name}"
        _run_client.update_job(job=job).result()
        logger.info("Updated Cloud Run job %s", names.job_name)


def _execute_job(job_name: str) -> None:
    _run_client.run_job(name=f"{cfg.parent}/jobs/{job_name}").result()
    logger.info("Triggered immediate execution of Cloud Run job %s", job_name)


def _set_job_iam(job_name: str, sa_email: str, user_email: str) -> None:
    _run_client.set_iam_policy(
        request=iam_policy_pb2.SetIamPolicyRequest(
            resource=f"{cfg.parent}/jobs/{job_name}",
            policy=policy_pb2.Policy(
                bindings=[
                    policy_pb2.Binding(
                        role="roles/run.developer",
                        members=[f"serviceAccount:{sa_email}", f"user:{user_email}"],
                    )
                ]
            ),
        )
    )
    logger.info("Set IAM on Cloud Run job %s", job_name)


# ─── CLOUD SCHEDULER ─────────────────────────────────────────────────────────

def _upsert_scheduler(scheduler_name: str, job_name: str, sa_email: str) -> None:
    job_path    = f"{cfg.parent}/jobs/{scheduler_name}"
    run_job_uri = f"https://run.googleapis.com/v2/{cfg.parent}/jobs/{job_name}:run"

    scheduler_job = scheduler_v1.Job(
        name=job_path,
        schedule=SCHEDULE,
        time_zone=TIMEZONE,
        attempt_deadline=duration_pb2.Duration(seconds=300),
        http_target=scheduler_v1.HttpTarget(
            uri=run_job_uri,
            http_method=scheduler_v1.HttpMethod.POST,
            body=b"{}",
            oauth_token=scheduler_v1.OAuthToken(service_account_email=sa_email),
        ),
    )

    try:
        _scheduler_client.create_job(parent=cfg.parent, job=scheduler_job)
        logger.info("Created Cloud Scheduler job %s", scheduler_name)
    except AlreadyExists:
        _scheduler_client.update_job(job=scheduler_job)
        logger.info("Updated Cloud Scheduler job %s", scheduler_name)


# ─── CLOUD LOGGING LOG VIEW ──────────────────────────────────────────────────

def _upsert_log_view(job_name: str, user_id: str, user_email: str) -> None:
    """Create/update a scoped log view for the user's job and grant them access."""
    client      = _LoggingConfigClient()
    bucket_path = f"projects/{cfg.project_id}/locations/{cfg.location}/buckets/_Default"
    view_name   = f"clickup-weekly-report-{user_id}"
    view_path   = f"{bucket_path}/views/{view_name}"
    log_filter  = (
        f'resource.type="cloud_run_job"'
        f' AND resource.labels.job_name="{job_name}"'
    )

    view = _LogView(filter=log_filter)
    try:
        client.create_view(request={"parent": bucket_path, "view_id": view_name, "view": view})
        logger.info("Created log view %s", view_name)
    except AlreadyExists:
        view.name = view_path
        client.update_view(request={"name": view_path, "view": view})
        logger.info("Updated log view %s", view_name)

    # set_iam_policy is a full replace — always idempotent.
    client.set_iam_policy(
        request=iam_policy_pb2.SetIamPolicyRequest(
            resource=view_path,
            policy=policy_pb2.Policy(
                bindings=[
                    policy_pb2.Binding(
                        role="roles/logging.viewAccessor",
                        members=[f"user:{user_email}"],
                    )
                ]
            ),
        )
    )
    logger.info("Granted logging.viewAccessor on log view %s to %s", view_name, user_email)
