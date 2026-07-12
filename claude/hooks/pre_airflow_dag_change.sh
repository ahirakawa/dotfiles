#!/usr/bin/env bash
set -uo pipefail

DETECTOR="airflow_dag_change"
AUDIT_LOG="${HOME}/.claude/harness_audit.jsonl"

json_escape() {
  jq -Rn --arg v "${1-}" '$v'
}

audit() {
  local session_id="${1-}"
  local file_path="${2-}"
  local change_type="${3-}"
  local old_value="${4-}"
  local new_value="${5-}"
  local decision="${6-}"

  mkdir -p "${HOME}/.claude" 2>/dev/null || true
  printf '{"detector":%s,"session_id":%s,"file_path":%s,"change_type":%s,"old_value":%s,"new_value":%s,"decision":%s}\n' \
    "$(json_escape "$DETECTOR")" \
    "$(json_escape "$session_id")" \
    "$(json_escape "$file_path")" \
    "$(json_escape "$change_type")" \
    "$(json_escape "$old_value")" \
    "$(json_escape "$new_value")" \
    "$(json_escape "$decision")" >> "$AUDIT_LOG" 2>/dev/null || true
}

block() {
  local session_id="${1-}"
  local file_path="${2-}"
  local change_type="${3-}"
  local old_value="${4-}"
  local new_value="${5-}"

  audit "$session_id" "$file_path" "$change_type" "$old_value" "$new_value" "block"
  {
    echo "[blocked] pre_airflow_dag_change: high-impact DAG attribute change"
    echo "  File: $file_path"
    echo "  Change: $change_type: $old_value -> $new_value"
    echo "  Bypass: CLAUDE_HOOK_BYPASS=1 claude"
  } >&2
  exit 2
}

# Non-blocking warnings are collected and delivered via additionalContext at
# the end (stderr at exit 0 never reaches Claude).
WARN_BUF=""
warn() {
  local session_id="${1-}"
  local file_path="${2-}"
  local change_type="${3-}"
  local old_value="${4-}"
  local new_value="${5-}"

  audit "$session_id" "$file_path" "$change_type" "$old_value" "$new_value" "warn"
  local line="[airflow-dag warning] $change_type: $old_value -> $new_value ($file_path)"
  if [[ -z "$WARN_BUF" ]]; then
    WARN_BUF="$line"
  else
    WARN_BUF="${WARN_BUF}
${line}"
  fi
}

extract_schedule() {
  printf '%s\n' "${1-}" |
    grep -E "schedule(_interval)?[[:space:]]*=[[:space:]]*['\"][^'\"]+['\"]" |
    sed -E "s/.*schedule(_interval)?[[:space:]]*=[[:space:]]*['\"]([^'\"]+)['\"].*/\\2/" |
    head -n 1
}

extract_simple_attr() {
  local text="${1-}"
  local attr="${2-}"
  printf '%s\n' "$text" |
    grep -E "${attr}[[:space:]]*=[[:space:]]*['\"][^'\"]+['\"]" |
    sed -E "s/.*${attr}[[:space:]]*=[[:space:]]*['\"]([^'\"]+)['\"].*/\\1/" |
    head -n 1
}

extract_expr_attr() {
  local text="${1-}"
  local attr="${2-}"
  printf '%s\n' "$text" |
    grep -E "${attr}[[:space:]]*=[[:space:]]*[^,)]+" |
    sed -E "s/.*${attr}[[:space:]]*=[[:space:]]*([^,)]*).*/\\1/" |
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' |
    head -n 1
}

extract_bool_attr() {
  local text="${1-}"
  local attr="${2-}"
  printf '%s\n' "$text" |
    grep -E "${attr}[[:space:]]*=[[:space:]]*(True|False)" |
    sed -E "s/.*${attr}[[:space:]]*=[[:space:]]*(True|False).*/\\1/" |
    head -n 1
}

extract_int_attr() {
  local text="${1-}"
  local attr="${2-}"
  printf '%s\n' "$text" |
    grep -E "${attr}[[:space:]]*=[[:space:]]*[0-9]+" |
    sed -E "s/.*${attr}[[:space:]]*=[[:space:]]*([0-9]+).*/\\1/" |
    head -n 1
}

extract_tasks() {
  local text="${1-}"
  printf '%s\n' "$text" |
    sed -E 's/^[[:space:]]+//' |
    grep -E "([A-Za-z_][A-Za-z0-9_]*Operator|@task)[^#]*task_id[[:space:]]*=[[:space:]]*['\"][^'\"]+['\"]|task_id[[:space:]]*=[[:space:]]*['\"][^'\"]+['\"]" |
    while IFS= read -r line; do
      task_id="$(printf '%s\n' "$line" | sed -E "s/.*task_id[[:space:]]*=[[:space:]]*['\"]([^'\"]+)['\"].*/\\1/")"
      operator="$(printf '%s\n' "$line" | sed -E 's/^.*([A-Za-z_][A-Za-z0-9_]*Operator)[[:space:]]*\(.*/\1/')"
      if [[ "$operator" == "$line" ]]; then
        operator="unknown"
      fi
      printf '%s\t%s\n' "$task_id" "$operator"
    done | sort -u
}

extract_task_ids() {
  extract_tasks "${1-}" | awk -F '	' '{print $1}' | sort -u
}

operator_for_task() {
  local tasks="${1-}"
  local task_id="${2-}"
  printf '%s\n' "$tasks" | awk -F '	' -v id="$task_id" '$1 == id {print $2; exit}'
}

changed() {
  [[ -n "${1-}" || -n "${2-}" ]] && [[ "${1-}" != "${2-}" ]]
}

input="$(cat 2>/dev/null || true)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // .tool // empty' 2>/dev/null || true)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"

if [[ "${CLAUDE_HOOK_BYPASS-}" == "1" ]]; then
  exit 0
fi

case "$tool_name" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // .file_path // empty' 2>/dev/null || true)"
if ! printf '%s\n' "$file_path" | grep -E '(^|/)(dags|airflow_dags|airflow/dags)/[^/]+\.py$' >/dev/null 2>&1; then
  exit 0
fi

old=""
new=""

case "$tool_name" in
  Edit)
    old="$(printf '%s' "$input" | jq -r '.tool_input.old_string // empty' 2>/dev/null || true)"
    new="$(printf '%s' "$input" | jq -r '.tool_input.new_string // empty' 2>/dev/null || true)"
    ;;
  Write)
    if [[ -f "$file_path" ]]; then
      old="$(sed -n '1,2000p' "$file_path" 2>/dev/null || true)"
    fi
    new="$(printf '%s' "$input" | jq -r '.tool_input.content // empty' 2>/dev/null || true)"
    ;;
  MultiEdit)
    old="$(printf '%s' "$input" | jq -r '.tool_input.edits[]? | .old_string // empty' 2>/dev/null || true)"
    new="$(printf '%s' "$input" | jq -r '.tool_input.edits[]? | .new_string // empty' 2>/dev/null || true)"
    ;;
esac

old_schedule="$(extract_schedule "$old")"
new_schedule="$(extract_schedule "$new")"
old_start_date="$(extract_expr_attr "$old" "start_date")"
new_start_date="$(extract_expr_attr "$new" "start_date")"
old_owner="$(extract_simple_attr "$old" "owner")"
new_owner="$(extract_simple_attr "$new" "owner")"
old_dag_id="$(extract_simple_attr "$old" "dag_id")"
new_dag_id="$(extract_simple_attr "$new" "dag_id")"
old_catchup="$(extract_bool_attr "$old" "catchup")"
new_catchup="$(extract_bool_attr "$new" "catchup")"
old_max_active_runs="$(extract_int_attr "$old" "max_active_runs")"
new_max_active_runs="$(extract_int_attr "$new" "max_active_runs")"
old_retries="$(extract_expr_attr "$old" "retries")"
new_retries="$(extract_expr_attr "$new" "retries")"
old_retry_delay="$(extract_expr_attr "$old" "retry_delay")"
new_retry_delay="$(extract_expr_attr "$new" "retry_delay")"
old_tasks="$(extract_tasks "$old")"
new_tasks="$(extract_tasks "$new")"

if changed "$old_schedule" "$new_schedule"; then
  block "$session_id" "$file_path" "schedule" "${old_schedule:-none}" "${new_schedule:-none}"
fi

if changed "$old_dag_id" "$new_dag_id"; then
  block "$session_id" "$file_path" "dag_id" "${old_dag_id:-none}" "${new_dag_id:-none}"
fi

if changed "$old_owner" "$new_owner"; then
  block "$session_id" "$file_path" "owner" "${old_owner:-none}" "${new_owner:-none}"
fi

if [[ "$old_catchup" == "False" && "$new_catchup" == "True" ]]; then
  block "$session_id" "$file_path" "catchup" "$old_catchup" "$new_catchup"
fi

if [[ "$old_max_active_runs" =~ ^[0-9]+$ && "$new_max_active_runs" =~ ^[0-9]+$ ]]; then
  if (( old_max_active_runs > 0 && new_max_active_runs >= old_max_active_runs * 2 )); then
    block "$session_id" "$file_path" "max_active_runs" "$old_max_active_runs" "$new_max_active_runs"
  fi
fi

while IFS= read -r old_task_id; do
  [[ -z "$old_task_id" ]] && continue
  if ! printf '%s\n' "$new_tasks" | awk -F '	' -v id="$old_task_id" '$1 == id {found=1} END {exit found ? 0 : 1}'; then
    block "$session_id" "$file_path" "task_id_removed" "$old_task_id" "removed"
  fi
done <<EOF_TASK_REMOVAL
$(printf '%s\n' "$old_tasks" | awk -F '	' '{print $1}' | sort -u)
EOF_TASK_REMOVAL

while IFS= read -r old_task_id; do
  [[ -z "$old_task_id" ]] && continue
  old_operator="$(operator_for_task "$old_tasks" "$old_task_id")"
  new_operator="$(operator_for_task "$new_tasks" "$old_task_id")"
  if [[ -n "$old_operator" && -n "$new_operator" && "$old_operator" != "unknown" && "$new_operator" != "unknown" && "$old_operator" != "$new_operator" ]]; then
    block "$session_id" "$file_path" "operator_class" "$old_task_id:$old_operator" "$old_task_id:$new_operator"
  fi
done <<EOF_OPERATOR_CHANGE
$(printf '%s\n' "$old_tasks" | awk -F '	' '{print $1}' | sort -u)
EOF_OPERATOR_CHANGE

if changed "$old_start_date" "$new_start_date"; then
  warn "$session_id" "$file_path" "start_date" "${old_start_date:-none}" "${new_start_date:-none}"
fi

if [[ "$old_max_active_runs" =~ ^[0-9]+$ && "$new_max_active_runs" =~ ^[0-9]+$ ]]; then
  if (( new_max_active_runs < old_max_active_runs )); then
    warn "$session_id" "$file_path" "max_active_runs_decreased" "$old_max_active_runs" "$new_max_active_runs"
  fi
fi

while IFS= read -r new_task_line; do
  [[ -z "$new_task_line" ]] && continue
  new_task_id="$(printf '%s\n' "$new_task_line" | awk -F '	' '{print $1}')"
  new_operator="$(printf '%s\n' "$new_task_line" | awk -F '	' '{print $2}')"
  if ! printf '%s\n' "$old_tasks" | awk -F '	' -v id="$new_task_id" '$1 == id {found=1} END {exit found ? 0 : 1}'; then
    warn "$session_id" "$file_path" "operator_class_added" "none" "$new_task_id:$new_operator"
  fi
done <<EOF_OPERATOR_ADDED
$new_tasks
EOF_OPERATOR_ADDED

if changed "$old_retries" "$new_retries"; then
  warn "$session_id" "$file_path" "retries" "${old_retries:-none}" "${new_retries:-none}"
fi

if changed "$old_retry_delay" "$new_retry_delay"; then
  warn "$session_id" "$file_path" "retry_delay" "${old_retry_delay:-none}" "${new_retry_delay:-none}"
fi

audit "$session_id" "$file_path" "none" "" "" "allow"

if [[ -n "$WARN_BUF" ]]; then
  jq -n --arg ctx "$WARN_BUF" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: $ctx
    }
  }'
fi

exit 0
