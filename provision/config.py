"""Runtime configuration loaded from the PROVISION_CONFIG secret."""

from __future__ import annotations

import dataclasses
import json
import os

# ─── JOB CONSTANTS ────────────────────────────────────────────────────────────

SCHEDULE        = "00 12 * * 4"  # Thursday at noon
TIMEZONE        = "Europe/Berlin"
JOB_TIMEOUT_S   = 600
JOB_MEMORY      = "512Mi"
JOB_MAX_RETRIES = 1


# ─── CONFIG ───────────────────────────────────────────────────────────────────

@dataclasses.dataclass(frozen=True)
class Config:
    project_id:       str
    location:         str
    repository:       str
    image_name:       str
    provisioning_key: str
    workspace_id:     str = ""
    folder_id:        str = ""
    lookback_days:    str = "7"
    page_prefix:      str = "CW"

    @classmethod
    def from_env(cls) -> Config:
        raw = json.loads(os.environ["PROVISION_CONFIG"])
        return cls(
            project_id=raw["project_id"],
            location=raw["location"],
            repository=raw["repository"],
            image_name=raw["image_name"],
            provisioning_key=raw["provisioning_key"],
            workspace_id=raw.get("workspace_id", ""),
            folder_id=raw.get("folder_id", ""),
            lookback_days=raw.get("lookback_days", "7"),
            page_prefix=raw.get("page_prefix", "CW"),
        )

    @property
    def image_uri(self) -> str:
        return f"{self.location}-docker.pkg.dev/{self.project_id}/{self.repository}/{self.image_name}:latest"

    @property
    def parent(self) -> str:
        return f"projects/{self.project_id}/locations/{self.location}"


# Loaded once at cold start; shared across warm invocations.
cfg = Config.from_env()
