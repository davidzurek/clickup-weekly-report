# ClickUp Weekly Report

Automatically fetches tasks and comments from ClickUp, generates a structured weekly progress report using Claude (Anthropic), and pushes it as a new page to a ClickUp Doc.

## How it works

1. Fetches all lists from a given ClickUp folder
2. Fetches tasks updated within the lookback window (filtered by assignee and status)
3. Fetches comments and threaded replies for each task
4. Merges everything into a single `merged.json`
5. Sends the data to Claude (`claude-sonnet-4-6`) to generate a markdown report
6. Pushes the report as a new page to a ClickUp Doc

---

## Repository structure

```
.
├── clickup-summary.sh       # Main script (fetch → merge → generate → push)
├── deploy.sh                # Admin, run once: enables APIs, builds image, deploys Cloud Function
├── setup-user-gcp.sh        # Admin, run per user: provisions Cloud Run job, Cloud Scheduler, secrets, IAM
├── setup-user-local.sh      # User, run in Cloud Shell: saves config and runs the report directly (no GCP resources)
├── Dockerfile               # Container image (debian + bash + curl + jq)
├── example.env              # Reference for .env variables (non-secret)
├── example.env.secrets      # Reference for .env.secrets variables (secret)
├── docs/
│   ├── gcp-setup.md         # Step-by-step GCP deployment guide
│   ├── prompt.md            # LLM instructions for report generation
│   └── report-template.md   # Markdown template for the weekly report
├── provision/               # Self-service Cloud Function for per-user GCP provisioning
│   ├── main.py              # HTTP entry point
│   ├── provisioner.py       # GCP provisioning logic
│   ├── config.py            # Config dataclass loaded from PROVISION_CONFIG secret
│   ├── models.py            # UserRequest and ResourceNames dataclasses
│   ├── form.py              # HTML setup form
│   └── requirements.txt     # Python dependencies
└── outputs/                 # Generated at runtime, gitignored
```

---

## Setup scripts explained

There are two setup scripts, each serving a different role:

**`deploy.sh`** — run **once by the admin** before any users are onboarded. It handles everything that is shared across all users: enabling GCP APIs, creating the Artifact Registry repository, building and pushing the Docker image, setting up service accounts and IAM, storing config in Secret Manager, and deploying the self-service Cloud Function. Re-run whenever the Docker image or Cloud Function code changes.

**`setup-user-gcp.sh`** — run **once per user by the admin**. It provisions every resource that belongs exclusively to one user: a dedicated service account, two Secret Manager secrets (ClickUp and Anthropic API keys), a Cloud Run job, and a Cloud Scheduler trigger. Resources are named with the user's ClickUp user ID as a suffix so multiple users can coexist in the same GCP project without collision. IAM bindings ensure each user can only access their own resources.

**`setup-user-local.sh`** — run **by the user themselves** inside Google Cloud Shell. It requires no GCP resources at all — no Cloud Run, no Cloud Scheduler, no Secret Manager. Config is written to `.env` and `.env.secrets` on Cloud Shell's persistent disk, and the report script is executed directly. The user needs to trigger it manually each week.

---

## Configuration

### `.env`

| Variable | Description | Example |
|---|---|---|
| `LOCATION` | GCP region | `europe-west3` |
| `PROJECT_ID` | GCP project ID | `my-project-id` |
| `REPOSITORY` | Artifact Registry repo name | `clickup` |
| `IMAGE_NAME` | Docker image name | `clickup-weekly-report` |
| `WORKSPACE_ID` | ClickUp workspace ID | `12345` |
| `FOLDER_ID` | ClickUp folder ID to fetch lists from | `12345` |
| `USER_ID` | ClickUp user ID to filter tasks by assignee | `12345` |
| `DOC_ID` | ClickUp Doc ID to push the report to | `1abc2-12345` |
| `PARENT_PAGE_ID` | Parent page ID inside the Doc | `1ab2-6789` |
| `LOOKBACK_DAYS` | How many days back to look for updates | `7` |
| `PAGE_PREFIX` | Prefix for the generated page name | `CW` |

### `.env.secrets`

| Variable | Description |
|---|---|
| `CU_API_KEY` | ClickUp personal API token |
| `ANTHROPIC_API_KEY` | Anthropic API key |

> Both files are gitignored. Never commit them.

---

## Deployment options

There are three ways to run this tool. Choose the one that fits your setup.

---

### Option A — GCP deployment (Cloud Run + Cloud Scheduler)

Each user gets their own isolated Cloud Run job, Cloud Scheduler trigger, and Secret Manager secrets. All users share a single Docker image stored in Artifact Registry.

**Step 1 — Admin runs once** to enable APIs, build the shared Docker image, and deploy the self-service Cloud Function:

```bash
bash deploy.sh
```

Requires a populated `.env` (copy `example.env` and fill in all values), Docker running locally, and `gcloud` authenticated as a project owner. At the end it prints a provisioning key and a Cloud Function URL — share both with your users.

**Step 2 — Admin runs per user** to provision that user's isolated resources:

```bash
bash setup-user-gcp.sh \
  --gcp-project-id    my-gcp-project \
  --user-email        user@example.com \
  --user-id           81687559 \
  --doc-id            2gcg7-284992 \
  --parent-page-id    2gcg7-435652 \
  --cu-api-key        pk_xxx \
  --anthropic-api-key sk-ant-xxx
```

Optional flags (defaults come from `example.env`): `--workspace-id`, `--folder-id`, `--lookback-days`, `--page-prefix`

Each user gets:
- A dedicated service account (`sa-cr-job-{USER_ID}`)
- Two secrets scoped to their account only (`cu-api-key-{USER_ID}`, `anthropic-api-key-{USER_ID}`)
- A Cloud Run job (`clickup-weekly-report-job-{USER_ID}`)
- A Cloud Scheduler trigger (every Thursday at 12:00 Berlin time)

**IAM isolation:** Each user's service account can only access their own secrets and trigger their own job. Users can view and manually trigger their own job but cannot see other users' resources.

#### Running the job manually

```bash
gcloud run jobs execute clickup-weekly-report-job-{USER_ID} --region {LOCATION}
```

#### Overriding job settings

**Persistent change** (applies to all future executions):

```bash
gcloud run jobs update clickup-weekly-report-job-{USER_ID} \
    --region {LOCATION} \
    --update-env-vars LOOKBACK_DAYS=14,PAGE_PREFIX=CW
```

**One-off override** via Cloud Scheduler:

```bash
gcloud scheduler jobs update http clickup-weekly-report-schedule-{USER_ID} \
    --location={LOCATION} \
    --message-body='{"overrides":{"containerOverrides":[{"args":["--lookback-days","14","--page-prefix","CW"]}]}}'
```

---

### Option B — Cloud Shell (no GCP resources)

Runs the report directly inside Google Cloud Shell. No Cloud Run, no Cloud Scheduler, no Secret Manager — config is saved to Cloud Shell's persistent disk. Cloud Shell already has `bash`, `curl`, and `jq` installed.

**First run** (pass your values once — saved for future runs):

```bash
bash setup-user-local.sh \
  --user-id           81687559 \
  --doc-id            2gcg7-284992 \
  --parent-page-id    2gcg7-435652 \
  --cu-api-key        pk_xxx \
  --anthropic-api-key sk-ant-xxx
```

**Subsequent runs** (config already saved):

```bash
bash setup-user-local.sh
```

The report runs immediately each time the script is executed. Scheduling is not automatic — the user triggers it manually.

---


## Running locally

### Requirements

- `bash`, `curl`, `jq`

### Run

```bash
./clickup-summary.sh
```

The script automatically sources `.env` and `.env.secrets` from its own directory. It also accepts CLI flags to override any value at runtime:

```bash
./clickup-summary.sh --lookback-days 14 --page-prefix "CW"
```

Available flags: `--workspace-id`, `--folder-id`, `--user-id`, `--doc-id`, `--parent-page-id`, `--lookback-days`, `--page-prefix`

### Output files (written to `outputs/`)

| File | Description |
|---|---|
| `tasks-updated.json` | Raw tasks fetched from ClickUp |
| `comments-updated.json` | Filtered comments per task |
| `threaded-comments-updated.json` | Threaded replies per comment |
| `merged.json` | Tasks with nested comments and threads |
| `weekly-report.md` | Final generated report |

---

## Finding your IDs and API keys

### ClickUp IDs

| Variable | Where to find it |
|---|---|
| `WORKSPACE_ID` | ClickUp URL: `app.clickup.com/{workspace_id}/` |
| `FOLDER_ID` | ClickUp URL when inside a folder: `.../f/{folder_id}` |
| `DOC_ID` / `PARENT_PAGE_ID` | ClickUp Doc URL: `.../docs/{doc_id}/page/{page_id}` |

**`USER_ID`** — via ClickUp UI:
1. In the sidebar, click **Teams**
2. Search for your username
3. Hover over your user box → click the three dots (top-right corner)
4. Copy your **Member ID**

**`CU_API_KEY`** — via ClickUp UI:
1. Top-right corner → click your avatar → **Settings**
2. Under **All Settings**, click **ClickUp API**
3. Generate a new personal API token and store it somewhere safe

### Anthropic API key

**`ANTHROPIC_API_KEY`** — via Claude console:
1. Go to [platform.claude.com](https://platform.claude.com/)
2. Bottom-right corner → **Settings**
3. Navigate to **API Keys**
4. Create a new key and store it somewhere safe
