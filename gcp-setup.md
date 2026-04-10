## Prerequisites

### How to obtain ClickUp User ID via UI
* Login to ClickUp
* Select your workspace
* On the sidebar section click "Teams"
* Search for you username
* Hover over your username box, click on the top right corner the three dots
* Copy your `member ID`

### How to obtain ClickUp API Key via UI
* Login to ClickUp
* Top right corner, click on your avatar
* Select `Settings`
* Under `All Settings` click on `ClickUp API`
* Generate a new API token
* Store it somewhere safe

### How to obtain Claud API Key via UI
* Login to https://platform.claude.com/
* Bottom right corner, select settings
* Navigate to `API Keys` section
* Create a new API key
* Store it somewhere safe

## GCP Setup
* make sure you are signed in with your work email in your browser
* open GCP cloud shell in browser: https://console.cloud.google.com/welcome?project=crfe-sbox-int&cloudshell=true
* manually upload zip file: click on 3 dots at the top right position of the shell and select "Upload". Select the zip file and confirm with "Upload".
* execute the following commands:

```bash
# Unzip file and change to the script directory
unzip clickup-weekly-report-main.zip && rm clickup-weekly-report-main.zip && cd clickup-weekly-report-main
```

### Automatic Setup
* Run the following command with the necessary argument flags

Required flags:
```bash
./setup-args.sh \
    --user-id <id> \
    --doc-id <id> \
    --parent-page-id <id> \
    --cu-api-key <key> \
    --anthropic-api-key <key>
```

Optional flags (defaults from `example.env` are used if omitted):
```bash
    --gcp-project-id <id> \
    --workspace-id <id> \
    --folder-id <id> \
    --lookback-days <days>
```