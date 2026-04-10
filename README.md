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
├── setup.sh                # GCP provisioning & deployment script
├── setup-args.sh           # Same as setup.sh, but accepts CLI flags to auto-populate .env files
├── Dockerfile              # Container image (debian + bash + curl + jq)
├── docs/
│   ├── prompt.md           # LLM instructions for report generation
│   └── report-template.md  # Markdown template for the weekly report
├── outputs/                # Generated at runtime, gitignored
├── example.env             # Reference for .env variables (no secrets)
├── example.env.secrets     # Reference for .env.secrets variables (no secrets)
└── .gitignore
```

---

## Configuration

Copy the example files and fill in your values:

```bash
cp example.env .env
cp example.env.secrets .env.secrets
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
./clickup-summary.sh
```

The script automatically sources `.env` and `.env.secrets` from its own directory if they exist — no need to pre-source them manually.

The script also accepts CLI flags to override any `.env` value at runtime:

```bash
./clickup-summary.sh \
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

### What `setup.sh` does

1. Enables required GCP APIs (`secretmanager`, `run`, `artifactregistry`)
2. Creates two Secret Manager secrets: `cu-api-key` and `anthropic-api-key`
3. Creates a service account `sa-cr-job` with access to those secrets
4. Creates an Artifact Registry Docker repository
5. Builds and pushes the Docker image
6. Deploys a Cloud Run job using the image
7. Creates a Cloud Scheduler job (Thursday at 12:00 Berlin time)

### Deploy

**Option A — manual setup:** fill in `.env` and `.env.secrets` yourself, then run:

```bash
bash setup.sh
```

**Option B — automated setup via flags:** pass all required values directly and let `setup-args.sh` populate the env files for you:

```bash
bash setup-args.sh \
  --user-id <id> \
  --doc-id <id> \
  --parent-page-id <id> \
  --cu-api-key <key> \
  --anthropic-api-key <key>
```

This copies `example.env` → `.env` and `example.env.secrets` → `.env.secrets`, substitutes your values in-place, then runs the full deployment.

**Option C — GCP Cloud Shell (no local tooling required):**

1. Make sure you are signed in with your work account in the browser
2. Open [GCP Cloud Shell](https://console.cloud.google.com/welcome?cloudshell=true) for your project
3. Upload the repo zip: click the three-dot menu (top-right of the shell) → **Upload** → select the zip → confirm
4. Run:

```bash
unzip clickup-weekly-report-main.zip && rm clickup-weekly-report-main.zip && cd clickup-weekly-report-main
```

5. Then run `setup-args.sh` with the required flags (same as Option B above)

### Run the Cloud Run job manually

```bash
gcloud run jobs execute $JOB_NAME --region $LOCATION
```

### Schedule (optional)

A Cloud Scheduler job is created at the end of both `setup.sh` and `setup-args.sh` (Thursday at 12:00 Berlin time). Adjust the `--schedule` and `--time-zone` flags as needed.

### Overriding job arguments

You have two places to override the default values, depending on how permanent the change is:

**Option 1 — Cloud Run job environment variables** (persistent default for all executions):

```bash
gcloud run jobs update $JOB_NAME \
    --region $LOCATION \
    --update-env-vars LOOKBACK_DAYS=14,PAGE_PREFIX=CW
```

Use this when you want to change the default for every run going forward.

**Option 2 — Cloud Scheduler message body** (per-schedule override):

Cloud Scheduler triggers the job via the Cloud Run Jobs API. You can pass runtime argument overrides in `--message-body` without redeploying or changing the job's defaults:

```bash
gcloud scheduler jobs update http clickup-weekly-report-schedule \
    --location=$LOCATION \
    --message-body='{"overrides":{"containerOverrides":[{"args":["--lookback-days","14","--page-prefix","CW"]}]}}'
```

Use this when you want a specific schedule to behave differently from the job's defaults (e.g. a separate scheduler job for a different team or folder).

The `args` array maps directly to the CLI flags accepted by `clickup-summary.sh`. To run with no overrides, pass an empty body:

```bash
--message-body='{}'
```

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
