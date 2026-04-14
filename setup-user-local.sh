#!/bin/bash
# Runs the ClickUp weekly report directly inside Google Cloud Shell.
# No GCP resources are created — no Cloud Run, no Cloud Scheduler, no Secret Manager.
#
# Config is written to .env and .env.secrets on Cloud Shell's persistent disk
# (your $HOME directory persists across Cloud Shell sessions).
# On subsequent runs the script re-uses the saved config, so you only need
# to pass flags the first time or when you want to update a value.
#
# Cloud Shell already has bash, curl, and jq installed — no setup needed.
#
# Usage (first time):
#   bash setup-user-local.sh \
#     --user-id           81687559 \
#     --doc-id            2gcg7-284992 \
#     --parent-page-id    2gcg7-435652 \
#     --cu-api-key        pk_xxx \
#     --llm-api-key       sk-xxx
#
# Subsequent runs (re-use saved config, just run the report):
#   bash setup-user-local.sh
#
# Optional overrides (defaults from example.env):
#   --workspace-id  <id>
#   --folder-id     <id>
#   --lookback-days <days>
#   --page-prefix   <prefix>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── PARSE FLAGS ─────────────────────────────────────────────────────────────

USER_ID_ARG=""
DOC_ID_ARG=""
PARENT_PAGE_ID_ARG=""
CU_API_KEY_ARG=""
LLM_API_KEY_ARG=""
WORKSPACE_ID_ARG=""
FOLDER_ID_ARG=""
LOOKBACK_DAYS_ARG=""
PAGE_PREFIX_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user-id)           USER_ID_ARG="$2";           shift 2 ;;
        --doc-id)            DOC_ID_ARG="$2";            shift 2 ;;
        --parent-page-id)    PARENT_PAGE_ID_ARG="$2";    shift 2 ;;
        --cu-api-key)        CU_API_KEY_ARG="$2";        shift 2 ;;
        --llm-api-key)       LLM_API_KEY_ARG="$2";       shift 2 ;;
        --workspace-id)      WORKSPACE_ID_ARG="$2";      shift 2 ;;
        --folder-id)         FOLDER_ID_ARG="$2";         shift 2 ;;
        --lookback-days)     LOOKBACK_DAYS_ARG="$2";     shift 2 ;;
        --page-prefix)       PAGE_PREFIX_ARG="$2";       shift 2 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

# ─── POPULATE .env FROM example.env IF NOT PRESENT ───────────────────────────

if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    echo "==> .env not found, generating from example.env"
    cp "$SCRIPT_DIR/example.env" "$SCRIPT_DIR/.env"
fi

# Apply any overrides passed as flags
[[ -n "$USER_ID_ARG"        ]] && sed -i "s|^USER_ID=.*|USER_ID=\"$USER_ID_ARG\"|"                 "$SCRIPT_DIR/.env"
[[ -n "$DOC_ID_ARG"         ]] && sed -i "s|^DOC_ID=.*|DOC_ID=\"$DOC_ID_ARG\"|"                    "$SCRIPT_DIR/.env"
[[ -n "$PARENT_PAGE_ID_ARG" ]] && sed -i "s|^PARENT_PAGE_ID=.*|PARENT_PAGE_ID=\"$PARENT_PAGE_ID_ARG\"|" "$SCRIPT_DIR/.env"
[[ -n "$WORKSPACE_ID_ARG"   ]] && sed -i "s|^WORKSPACE_ID=.*|WORKSPACE_ID=\"$WORKSPACE_ID_ARG\"|"  "$SCRIPT_DIR/.env"
[[ -n "$FOLDER_ID_ARG"      ]] && sed -i "s|^FOLDER_ID=.*|FOLDER_ID=\"$FOLDER_ID_ARG\"|"           "$SCRIPT_DIR/.env"
[[ -n "$LOOKBACK_DAYS_ARG"  ]] && sed -i "s|^LOOKBACK_DAYS=.*|LOOKBACK_DAYS=\"$LOOKBACK_DAYS_ARG\"|" "$SCRIPT_DIR/.env"
[[ -n "$PAGE_PREFIX_ARG"    ]] && sed -i "s|^PAGE_PREFIX=.*|PAGE_PREFIX=\"$PAGE_PREFIX_ARG\"|"      "$SCRIPT_DIR/.env"

# ─── POPULATE .env.secrets FROM example.env.secrets IF NOT PRESENT ───────────

if [[ ! -f "$SCRIPT_DIR/.env.secrets" ]]; then
    echo "==> .env.secrets not found, generating from example.env.secrets"
    cp "$SCRIPT_DIR/example.env.secrets" "$SCRIPT_DIR/.env.secrets"
fi

[[ -n "$CU_API_KEY_ARG"        ]] && sed -i "s|^CU_API_KEY=.*|CU_API_KEY=\"$CU_API_KEY_ARG\"|"               "$SCRIPT_DIR/.env.secrets"
[[ -n "$LLM_API_KEY_ARG" ]] && sed -i "s|^LLM_API_KEY=.*|LLM_API_KEY=\"$LLM_API_KEY_ARG\"|" "$SCRIPT_DIR/.env.secrets"

# ─── VALIDATE REQUIRED VALUES ARE SET ────────────────────────────────────────
# Source both files so we can check the final resolved values.

set -a && source "$SCRIPT_DIR/.env" && source "$SCRIPT_DIR/.env.secrets" && set +a

MISSING=()
[[ "${USER_ID:-}"           == "my-user-id"           || -z "${USER_ID:-}"           ]] && MISSING+=("--user-id")
[[ "${DOC_ID:-}"            == "my-doc-id"            || -z "${DOC_ID:-}"            ]] && MISSING+=("--doc-id")
[[ "${PARENT_PAGE_ID:-}"    == "my-parent-page-id"    || -z "${PARENT_PAGE_ID:-}"    ]] && MISSING+=("--parent-page-id")
[[ "${CU_API_KEY:-}"        == "my-cu-api-key"        || -z "${CU_API_KEY:-}"        ]] && MISSING+=("--cu-api-key")
[[ "${LLM_API_KEY:-}" == "my-llm-api-key" || -z "${LLM_API_KEY:-}" ]] && MISSING+=("--llm-api-key")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "Error: the following required values are missing or still set to placeholder defaults:"
    for flag in "${MISSING[@]}"; do
        echo "  $flag"
    done
    echo ""
    echo "Pass them as flags, e.g.:"
    echo "  bash setup-user-local.sh --user-id 12345 --doc-id abc ..."
    exit 1
fi

# ─── ENSURE outputs/ DIRECTORY EXISTS ────────────────────────────────────────

mkdir -p "$SCRIPT_DIR/outputs"

# ─── RUN THE REPORT ──────────────────────────────────────────────────────────

echo "==> Config saved. Running report now..."
echo ""
bash "$SCRIPT_DIR/clickup-summary.sh"
