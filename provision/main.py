"""
Cloud Function: provision_user

Self-service provisioning endpoint for the ClickUp Weekly Report tool.
Accepts a JSON POST request with a user's values and creates all per-user
GCP resources: service account, Secret Manager secrets, Cloud Run job,
Cloud Scheduler trigger, and IAM bindings.

Replaces setup-user-gcp.sh. The function's service account holds all
provisioning permissions — individual users only need invoker access to
this function.

Secrets (mounted via --set-secrets at deploy time, avoids org policy on env var names):
  PROVISION_CONFIG  JSON string containing all config and the provisioning key:
                    {
                      "project_id":       "...",
                      "location":         "...",
                      "repository":       "...",
                      "image_name":       "...",
                      "workspace_id":     "...",
                      "folder_id":        "...",
                      "lookback_days":    "7",
                      "page_prefix":      "CW",
                      "provisioning_key": "..."
                    }

Request body (POST application/json):
  {
    "provisioning_key":  "shared-secret-from-admin", <- required
    "user_email":        "user@example.com",          <- required
    "user_id":           "81687559",                  <- required
    "doc_id":            "2gcg7-284992",              <- required
    "parent_page_id":    "2gcg7-435652",              <- required
    "cu_api_key":        "pk_xxx",                    <- required
    "anthropic_api_key": "sk-ant-xxx",                <- required
    "workspace_id":      "2634247",                   <- optional, falls back to value in PROVISION_CONFIG
    "folder_id":         "90121162200",               <- optional, falls back to value in PROVISION_CONFIG
    "lookback_days":     "7",                         <- optional
    "page_prefix":       "CW"                         <- optional
  }

Response (200):
  {
    "status":          "ok",
    "service_account": "sa-cr-job-81687559@project.iam.gserviceaccount.com",
    "secrets":         ["cu-api-key-81687559", "anthropic-api-key-81687559"],
    "cloud_run_job":   "clickup-weekly-report-job-81687559",
    "scheduler":       "clickup-weekly-report-schedule-81687559"
  }
"""

from __future__ import annotations

import logging

import functions_framework

from config import cfg
from form import serve_form
from models import ResourceNames, UserRequest
from provisioner import job_console_url, provision

logger = logging.getLogger(__name__)


@functions_framework.http
def provision_user(request):
    if request.method == "GET":
        return serve_form(), 200, {"Content-Type": "text/html"}

    if request.method != "POST":
        return {"error": "Method not allowed"}, 405

    body = request.get_json(silent=True)
    if not body:
        return {"error": "Request body must be JSON"}, 400

    if body.get("provisioning_key") != cfg.provisioning_key:
        return {"error": "Invalid provisioning key"}, 403

    try:
        req   = UserRequest.from_body(body)
        names = ResourceNames.for_user(req.user_id)
    except ValueError as e:
        return {"error": str(e)}, 400

    logger.info("Provisioning user_email=%s user_id=%s", req.user_email, req.user_id)

    try:
        provision(req, names)
    except Exception:
        logger.exception("Provisioning failed for user_id=%s", req.user_id)
        return {"error": "Provisioning failed — check Cloud Function logs"}, 500

    logger.info("Provisioning complete for user_id=%s", req.user_id)
    return {
        "status":          "ok",
        "service_account": names.sa_email,
        "secrets":         [names.cu_secret_name, names.anthropic_secret_name],
        "cloud_run_job":   names.job_name,
        "scheduler":       names.scheduler_name,
        "job_console_url": job_console_url(names),
    }, 200
