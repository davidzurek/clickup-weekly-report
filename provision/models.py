"""Request and resource-name models for the provisioning flow."""

from __future__ import annotations

import dataclasses
import re

from config import cfg

# user_id is suffixed onto GCP resource names (SA IDs, secret names, job names).
# SA IDs are capped at 30 chars; with the "sa-cr-job-" (10 char) prefix that
# leaves 20 for the user_id itself. Restrict to the alphabet that all the
# target resource types accept without escaping.
_USER_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,18}[a-z0-9]$|^[a-z0-9]$")


@dataclasses.dataclass(frozen=True)
class UserRequest:
    """Validated, fully-resolved user input from the HTTP POST body."""

    user_email:         str
    user_id:            str
    doc_id:             str
    parent_page_id:     str
    cu_api_key:         str
    llm_api_key:        str
    workspace_id:       str
    folder_id:          str
    lookback_days:      str
    page_prefix:        str
    execute_immediately: bool

    @classmethod
    def from_body(cls, body: dict) -> UserRequest:
        required = ["user_email", "user_id", "doc_id", "parent_page_id", "cu_api_key", "llm_api_key"]
        missing = [f for f in required if not body.get(f)]
        if missing:
            raise ValueError(f"Missing required fields: {', '.join(missing)}")

        user_id = str(body["user_id"]).strip().lower()
        if not _USER_ID_RE.match(user_id):
            raise ValueError(
                "user_id must be 1-20 characters, lowercase alphanumeric or hyphens, "
                "and cannot start or end with a hyphen"
            )

        workspace_id = body.get("workspace_id") or cfg.workspace_id
        folder_id    = body.get("folder_id")    or cfg.folder_id
        if not workspace_id or not folder_id:
            raise ValueError(
                "workspace_id and folder_id are required — pass them as fields or set defaults in PROVISION_CONFIG"
            )

        return cls(
            user_email=body["user_email"],
            user_id=user_id,
            doc_id=body["doc_id"],
            parent_page_id=body["parent_page_id"],
            cu_api_key=body["cu_api_key"],
            llm_api_key=body["llm_api_key"],
            workspace_id=workspace_id,
            folder_id=folder_id,
            lookback_days=body.get("lookback_days") or cfg.lookback_days,
            page_prefix=body.get("page_prefix")    or cfg.page_prefix,
            execute_immediately=body.get("execute_immediately", "no").strip().lower() == "yes",
        )


@dataclasses.dataclass(frozen=True)
class ResourceNames:
    """GCP resource names derived from a user ID."""

    sa_name:               str
    sa_email:              str
    job_name:              str
    scheduler_name:        str
    cu_secret_name:        str
    llm_secret_name:       str

    @classmethod
    def for_user(cls, user_id: str) -> ResourceNames:
        sa_name = f"sa-cr-job-{user_id}"
        return cls(
            sa_name=sa_name,
            sa_email=f"{sa_name}@{cfg.project_id}.iam.gserviceaccount.com",
            job_name=f"clickup-weekly-report-job-{user_id}",
            scheduler_name=f"clickup-weekly-report-schedule-{user_id}",
            cu_secret_name=f"cu-api-key-{user_id}",
            llm_secret_name=f"llm-api-key-{user_id}",
        )
