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
├── clickup-summary.sh      # Main script (fetch → merge → generate → push)
├── taskfile.sh             # GCP provisioning & deployment script
├── Dockerfile              # Container image (debian + bash + curl + jq)
├── docs/
│   ├── prompt.md           # LLM instructions for report generation
│   └── report-template.md  # Markdown template for the weekly report
├── outputs/                # Generated at runtime, gitignored
├── dummy.env               # Reference for .env variables (no secrets)
├── dummy.env.secrets       # Reference for .env.secrets variables (no secrets)
└── .gitignore
```

---

## Configuration

Copy the dummy files and fill in your values:

```bash
cp dummy.env .env
cp dummy.env.secrets .env.secrets
```

### `.env`

| Variable | Description | Example |
|---|---|---|
| `LOCATION` | GCP region | `europe-west3` |
| `PROJECT_ID` | GCP project ID | `my-project-id` |
| `REPOSITORY` | Artifact Registry repo name | `clickup` |
| `IMAGE_NAME` | Docker image name | `clickup-weekly-report` |
| `JOB_NAME` | Cloud Run job name | `clickup-weekly-report-job` |
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

## Local execution

### Requirements

- `bash`
- `curl`
- `jq`

### Run

```bash
source .env && source .env.secrets
bash clickup-summary.sh
```

The script also accepts CLI flags to override any `.env` value at runtime:

```bash
bash clickup-summary.sh \
  --lookback-days 14 \
  --page-prefix "CW"
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

## Google Cloud deployment

### Requirements

- [Google Cloud SDK (`gcloud`)](https://cloud.google.com/sdk/docs/install)
- [Docker](https://docs.docker.com/get-docker/)
- A GCP project with billing enabled
- Permissions to create: Artifact Registry repos, Cloud Run jobs, Secret Manager secrets, Service Accounts, IAM bindings

### What `taskfile.sh` does

1. Enables required GCP APIs (`secretmanager`, `run`, `artifactregistry`)
2. Creates two Secret Manager secrets: `cu-api-key` and `anthropic-api-key`
3. Creates a service account `sa-cr-job` with access to those secrets
4. Creates an Artifact Registry Docker repository
5. Builds and pushes the Docker image
6. Deploys a Cloud Run job using the image

### Deploy

Make sure `.env` and `.env.secrets` are filled in, then run:

```bash
source .env && source .env.secrets
bash taskfile.sh
```

### Run the Cloud Run job manually

```bash
gcloud run jobs execute $JOB_NAME --region $LOCATION
```

### Schedule (optional)

A Cloud Scheduler example is included as a comment at the bottom of `taskfile.sh` (Thursday at 12:00 Berlin time). Uncomment and adjust as needed.

---

## Finding your ClickUp IDs

| What | Where to find it |
|---|---|
| `WORKSPACE_ID` | ClickUp URL: `app.clickup.com/{workspace_id}/` |
| `FOLDER_ID` | ClickUp URL when inside a folder: `.../f/{folder_id}` |
| `USER_ID` | Profile settings → Apps → API token page shows your user ID |
| `DOC_ID` / `PARENT_PAGE_ID` | ClickUp Doc URL: `.../docs/{doc_id}/page/{page_id}` |
| `CU_API_KEY` | Profile settings → Apps → API token |
