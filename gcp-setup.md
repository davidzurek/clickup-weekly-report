## Prerequisites

### How to obtain ClickUp User ID

1. Login to ClickUp
2. Select your workspace
3. In the sidebar, click **Teams**
4. Search for your username
5. Hover over your user box → click the three dots (top-right corner)
6. Copy your **Member ID**

### How to obtain ClickUp API Key

1. Login to ClickUp
2. Top-right corner → click your avatar → **Settings**
3. Under **All Settings**, click **ClickUp API**
4. Generate a new API token
5. Store it somewhere safe

### How to obtain Anthropic API Key

1. Login to [platform.claude.com](https://platform.claude.com/)
2. Bottom-right corner → **Settings**
3. Navigate to **API Keys**
4. Create a new API key
5. Store it somewhere safe

---

## Option A — GCP deployment (Cloud Run + Cloud Scheduler)

### Step 1: Admin setup (run once)

This step enables the required GCP APIs, creates the Artifact Registry repository, and builds and pushes the shared Docker image. Run this once per GCP project before onboarding any users.

**Requirements:**
- Docker running locally
- `gcloud` authenticated as a project owner or editor
- `.env` populated (copy `example.env` and fill in `PROJECT_ID`, `LOCATION`, `REPOSITORY`, `IMAGE_NAME`)

```bash
cp example.env .env
# fill in PROJECT_ID, LOCATION, REPOSITORY, IMAGE_NAME
./setup-project.sh
```

### Step 2: Per-user setup (run for each user)

This step provisions each user's isolated Cloud Run job, Cloud Scheduler trigger, Service Account, and Secret Manager secrets. The admin runs this once per user, passing their individual values as flags.

**Requirements:**
- `setup-project.sh` has been run
- `gcloud` authenticated as a project owner or editor

```bash
./setup-user-gcp.sh \
  --gcp-project-id    my-gcp-project \
  --user-email        user@example.com \
  --user-id           81687559 \
  --doc-id            2gcg7-284992 \
  --parent-page-id    2gcg7-435652 \
  --cu-api-key        pk_xxx \
  --anthropic-api-key sk-ant-xxx
```

Optional flags (fall back to values in `example.env` if omitted — pass them if your values differ from the defaults):

```
--workspace-id  <id>
--folder-id     <id>
--lookback-days <days>
--page-prefix   <prefix>
```

### Running from GCP Cloud Shell (no local tooling)

If you do not have `gcloud` or Docker installed locally, both steps can be run from GCP Cloud Shell in the browser.

1. Sign in with your work account in the browser
2. Open [GCP Cloud Shell](https://console.cloud.google.com/welcome?cloudshell=true)
3. Upload the repo zip: click the three-dot menu (top-right of the shell) → **Upload** → select the zip → confirm
4. Run:

```bash
unzip clickup-weekly-report-main.zip && rm clickup-weekly-report-main.zip && cd clickup-weekly-report-main
```

5. For Step 1 (admin setup), Docker is not available in Cloud Shell — the image build must be done locally or via Cloud Build. For Step 2 (per-user setup), Cloud Shell works without any additional tooling:

```bash
./setup-user-gcp.sh \
  --gcp-project-id    my-gcp-project \
  --user-email        user@example.com \
  --user-id           81687559 \
  --doc-id            2gcg7-284992 \
  --parent-page-id    2gcg7-435652 \
  --cu-api-key        pk_xxx \
  --anthropic-api-key sk-ant-xxx \
  --workspace-id      2634247 \
  --folder-id         90121162200
```

`--gcp-project-id` and `--user-email` are always required. `--workspace-id` and `--folder-id` are required if they are not already set in `example.env`.

---

## Option B — Cloud Shell only (no GCP resources)

For users who want to run the report directly in Cloud Shell without any GCP infrastructure. Config is saved to Cloud Shell's persistent home directory. Cloud Shell has `bash`, `curl`, and `jq` pre-installed.

1. Open [GCP Cloud Shell](https://console.cloud.google.com/welcome?cloudshell=true)
2. Upload and unzip the repo (same as above)
3. Run:

```bash
./setup-user-local.sh \
  --user-id           81687559 \
  --doc-id            2gcg7-284992 \
  --parent-page-id    2gcg7-435652 \
  --cu-api-key        pk_xxx \
  --anthropic-api-key sk-ant-xxx
```

Config is saved to `.env` and `.env.secrets` on the persistent disk. On subsequent runs, just call:

```bash
./setup-user-local.sh
```

The report runs immediately. There is no automatic schedule — the user triggers it manually each week.
