#!/bin/bash

# Script Start time
echo "Script started at: $(date)"

# Load environment variables from .env and .env.secrets
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/.env" ]]         && set -a && source "$SCRIPT_DIR/.env"         && set +a
[[ -f "$SCRIPT_DIR/.env.secrets" ]] && set -a && source "$SCRIPT_DIR/.env.secrets" && set +a

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace-id)   WORKSPACE_ID="$2";   shift 2 ;;
        --folder-id)      FOLDER_ID="$2";      shift 2 ;;
        --user-id)        USER_ID="$2";        shift 2 ;;
        --doc-id)         DOC_ID="$2";         shift 2 ;;
        --parent-page-id) PARENT_PAGE_ID="$2"; shift 2 ;;
        --lookback-days)  LOOKBACK_DAYS="$2";  shift 2 ;;
        --page-prefix)    PAGE_PREFIX="$2";    shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ "$(uname)" == "Darwin" ]]; then
    SINCE=$(date -v-"${LOOKBACK_DAYS}"d -v0H -v0M -v0S +%s)000
else
    SINCE=$(date -d "-${LOOKBACK_DAYS} days" -u +%s)000
fi
CURRENT_CW="$(date +'%V')"

# Fixed paths for input and output files
PROMPT_FILE="$SCRIPT_DIR/docs/prompt.md"
TEMPLATE_FILE="$SCRIPT_DIR/docs/report-template.md"
OUTPUT_TASKS="$SCRIPT_DIR/outputs/tasks-updated.json"
OUTPUT_COMMENTS="$SCRIPT_DIR/outputs/comments-updated.json"
OUTPUT_THREADED_COMMENTS="$SCRIPT_DIR/outputs/threaded-comments-updated.json"
OUTPUT_MERGED="$SCRIPT_DIR/outputs/merged.json"
OUTPUT_WEEKLY_REPORT="$SCRIPT_DIR/outputs/weekly-report.md"

# Clear output files before writing new data
> "$OUTPUT_TASKS"  
> "$OUTPUT_COMMENTS"
> "$OUTPUT_THREADED_COMMENTS"
> "$OUTPUT_MERGED"
> "$OUTPUT_WEEKLY_REPORT"


# GET ALL LIST IDS
LIST_IDS=()
while IFS= read -r id; do
    LIST_IDS+=("$id")
done < <(curl --silent --request GET \
     --url "https://api.clickup.com/api/v2/folder/$FOLDER_ID/list" \
     --header "Authorization: ${CU_API_KEY}" \
     --header 'accept: application/json' \
     | jq -r '.lists[].id')

echo "Fetched List IDs from folder $FOLDER_ID: ${LIST_IDS[@]}"
for id in "${LIST_IDS[@]}"; do
  curl --silent --request GET \
      --url "https://api.clickup.com/api/v2/list/$id/task?subtasks=true&statuses[]=in%20progress&statuses[]=to-do&statuses[]=done&assignees[]=${USER_ID}&date_updated_gt=$SINCE" \
      --header "Authorization: ${CU_API_KEY}" \
      --header 'accept: application/json' \
      | jq '.tasks[] | {id, custom_id, name, description, status: .status.status, date_updated: (.date_updated | tonumber / 1000 | strftime("%Y-%m-%d %H:%M:%S"))}' >> "$OUTPUT_TASKS"
done

# GET COMMENTS FOR EACH TASK AND FILTER BY DATE
while IFS= read -r task_id; do
    echo "Fetching comments for task: $task_id"

    curl --silent --request GET \
        --url "https://api.clickup.com/api/v2/task/${task_id}/comment" \
        --header "Authorization: ${CU_API_KEY}" \
        --header 'accept: application/json' \
        | jq --arg fk_task_id "$task_id" --argjson since "$SINCE" \
          '.comments[] | select((.date | tonumber) >= $since) | {fk_task_id: $fk_task_id, id, date, comment_text}' \
          >> "$OUTPUT_COMMENTS"

done < <(jq -r '.id' "$OUTPUT_TASKS")

echo "Done. Result saved to $OUTPUT_TASKS and $OUTPUT_COMMENTS"


# GET ALL THREADED COMMENTS
while IFS= read -r comment_id; do
    echo "Fetching threaded comments for comment: $comment_id"

    curl --silent --request GET \
        --url "https://api.clickup.com/api/v2/comment/${comment_id}/reply" \
        --header "Authorization: ${CU_API_KEY}" \
        --header 'accept: application/json' \
        | jq --arg comment_id "$comment_id" --argjson since "$SINCE" \
          '.comments[] | select((.date | tonumber) >= $since) | {fk_comment_id: $comment_id, id, date, comment_text}' \
          >> "$OUTPUT_THREADED_COMMENTS"

done < <(jq -r '.id' "$OUTPUT_COMMENTS")


# MERGE TASKS AND COMMENTS AND THREADED COMMENTS INTO A SINGLE FILE
jq -rs '
  # Split input into three groups: tasks (have "name"), comments (have "fk_task_id"), and threaded comments (have "fk_comment_id")
  (map(select(.name)) ) as $tasks |
  (map(select(.fk_task_id))) as $comments |
  (map(select(.fk_comment_id))) as $threaded_comments |

  # For each task, attach matching comments and threaded comments
  $tasks | map(
    . as $task |
    {
      id:          $task.id,
      custom_id:   $task.custom_id,
      name:        $task.name,
      description: $task.description,
      status:      $task.status,
      date_updated: $task.date_updated,
      comments: [
        $comments[] | select(.fk_task_id == $task.id) | . as $comment |
        $comment + {
          threaded_comments: [$threaded_comments[] | select(.fk_comment_id == $comment.id)]
        }
      ]
    }
  )
' "$OUTPUT_TASKS" "$OUTPUT_COMMENTS" "$OUTPUT_THREADED_COMMENTS" > "$OUTPUT_MERGED"

echo "Merged output saved to $OUTPUT_MERGED"


# API CALL TO LLM MODEL -> MAKE LLM READ `report-template.md`
echo "Generating weekly report using LLM..."
PROMPT_TEXT=$(cat "$PROMPT_FILE")
TEMPLATE_TEXT=$(cat "$TEMPLATE_FILE")
MERGED_TEXT=$(cat "$OUTPUT_MERGED")

if [[ -z "${LLM_API_KEY}" ]]; then
    echo "Error: LLM_API_KEY is not set." >&2
    exit 1
fi

if [[ "${LLM_API_KEY}" == sk-ant-* ]]; then
    echo "Using Anthropic API..."
    curl --silent --request POST \
        --url "https://api.anthropic.com/v1/messages" \
        --header "x-api-key: ${LLM_API_KEY}" \
        --header "anthropic-version: 2023-06-01" \
        --header "content-type: application/json" \
        --data "$(jq -n \
            --arg prompt "$PROMPT_TEXT" \
            --arg template "$TEMPLATE_TEXT" \
            --arg merged "$MERGED_TEXT" \
            '{
                model: "claude-sonnet-4-6",
                max_tokens: 4096,
                system: "You are a reporting assistant. Output only the raw markdown report — no preamble, no analysis, no commentary, no code fences. Nothing before or after the markdown content.",
                messages: [{
                    role: "user",
                    content: ("Instructions:\n\n" + $prompt + "\n\nReport template:\n\n" + $template + "\n\nData (merged.json):\n\n" + $merged)
                }]
            }')" \
        | jq -r '.content[0].text' > "$OUTPUT_WEEKLY_REPORT"

elif [[ "${LLM_API_KEY}" == sk-proj-* ]]; then
    echo "Using OpenAI API..."
    curl --silent --request POST \
        --url "https://api.openai.com/v1/chat/completions" \
        --header "Authorization: Bearer ${LLM_API_KEY}" \
        --header "content-type: application/json" \
        --data "$(jq -n \
            --arg prompt "$PROMPT_TEXT" \
            --arg template "$TEMPLATE_TEXT" \
            --arg merged "$MERGED_TEXT" \
            '{
                model: "gpt-4o",
                max_tokens: 4096,
                messages: [
                    {
                        role: "system",
                        content: "You are a reporting assistant. Output only the raw markdown report — no preamble, no analysis, no commentary, no code fences. Nothing before or after the markdown content."
                    },
                    {
                        role: "user",
                        content: ("Instructions:\n\n" + $prompt + "\n\nReport template:\n\n" + $template + "\n\nData (merged.json):\n\n" + $merged)
                    }
                ]
            }')" \
        | jq -r '.choices[0].message.content' > "$OUTPUT_WEEKLY_REPORT"

else
    echo "Error: LLM_API_KEY prefix not recognized. Expected 'sk-ant-' (Anthropic) or 'sk-proj-' (OpenAI)." >&2
    exit 1
fi

echo "Weekly report saved to $OUTPUT_WEEKLY_REPORT"


# PUSH THE REPORT OUTPUT TO CLICKUP
curl --silent --request POST \
     --url https://api.clickup.com/api/v3/workspaces/${WORKSPACE_ID}/docs/${DOC_ID}/pages \
     --header "Authorization: ${CU_API_KEY}" \
     --header 'accept: application/json' \
     --header 'content-type: application/json' \
     --data "$(jq -n \
       --arg content "$(cat "$OUTPUT_WEEKLY_REPORT")" \
       --arg current_cw "$CURRENT_CW" \
       --arg parent_page_id "$PARENT_PAGE_ID" \
       --arg page_prefix "$PAGE_PREFIX" \
       '{content_format: "text/md", parent_page_id: $parent_page_id, name: ($page_prefix + $current_cw), content: $content}')"

echo "Report pushed to ClickUp"
echo "Script finished at: $(date)"
