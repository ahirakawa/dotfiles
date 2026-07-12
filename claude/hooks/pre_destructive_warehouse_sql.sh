#!/usr/bin/env bash
set -uo pipefail

DETECTOR="destructive_warehouse_sql"
AUDIT_LOG="${HOME}/.claude/harness_audit.jsonl"

json_escape() {
  jq -Rn --arg v "${1:-}" '$v'
}

audit() {
  local session_id="${1:-unknown}"
  local cli_tool="${2:-unknown}"
  local verb="${3:-}"
  local target_object="${4:-}"
  local decision="${5:-allow}"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")"
  mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || true
  jq -cn \
    --arg detector "$DETECTOR" \
    --arg session_id "$session_id" \
    --arg cli_tool "$cli_tool" \
    --arg verb "$verb" \
    --arg target_object "$target_object" \
    --arg decision "$decision" \
    --arg ts "$ts" \
    '{detector:$detector,session_id:$session_id,cli_tool:$cli_tool,verb:$verb,target_object:$target_object,decision:$decision,ts:$ts}' \
    >> "$AUDIT_LOG" 2>/dev/null || true
}

emit_block() {
  local cli_tool="$1"
  local verb="$2"
  local target="$3"
  printf '[blocked] pre_destructive_warehouse_sql: destructive SQL via %s\n' "$cli_tool" >&2
  printf '  Detected verb: %s\n' "$verb" >&2
  printf '  Target: %s\n' "${target:-unknown}" >&2
  printf '  Bypass: CLAUDE_HOOK_BYPASS=1 claude\n' >&2
}

# Non-blocking warnings are collected and delivered via additionalContext at
# the end (stderr at exit 0 never reaches Claude).
WARN_BUF=""
emit_warn() {
  local reason="$1"
  local cli_tool="$2"
  local verb="${3:-}"
  local target="${4:-}"
  local msg="[warehouse-sql warning] ${reason} via ${cli_tool}"
  if [ -n "$verb" ]; then
    msg="${msg} (verb: ${verb}"
    if [ -n "$target" ]; then
      msg="${msg}, target: ${target}"
    fi
    msg="${msg})"
  fi
  if [ -z "$WARN_BUF" ]; then
    WARN_BUF="$msg"
  else
    WARN_BUF="${WARN_BUF}
${msg}"
  fi
}

first_nonempty() {
  while [ "$#" -gt 0 ]; do
    if [ -n "${1:-}" ] && [ "${1:-null}" != "null" ]; then
      printf '%s' "$1"
      return 0
    fi
    shift
  done
}

extract_command() {
  jq -r '
    .tool_input.command //
    .tool_input.input //
    .tool_input.script //
    .tool_input.args.command //
    .input.command //
    .command //
    ""
  '
}

normalize_sql() {
  printf '%s' "${1:-}" | tr '\n\r\t' '   '
}

read_sql_file() {
  local path="$1"
  local cwd="$2"
  local full="$path"
  path="${path%\"}"
  path="${path#\"}"
  path="${path%\'}"
  path="${path#\'}"
  if [ -z "$path" ]; then
    return 1
  fi
  case "$path" in
    /*) full="$path" ;;
    *) full="$cwd/$path" ;;
  esac
  if [ -f "$full" ]; then
    head -c 8192 "$full" 2>/dev/null || true
    return 0
  fi
  return 2
}

detect_destructive() {
  local sql
  sql="$(normalize_sql "$1")"
  awk '
    {
      s = tolower($0)
      if (match(s, /drop[[:space:]]+(database|schema|table|view|materialized[[:space:]]+view)[[:space:]]+((if[[:space:]]+exists[[:space:]]+)?["`A-Za-z0-9_.-]+)/)) {
        print "DROP|" substr(s, RSTART, RLENGTH)
        exit
      }
      if (match(s, /truncate[[:space:]]+table[[:space:]]+((if[[:space:]]+exists[[:space:]]+)?["`A-Za-z0-9_.-]+)/)) {
        print "TRUNCATE|" substr(s, RSTART, RLENGTH)
        exit
      }
      if (match(s, /delete[[:space:]]+from[[:space:]]+["`A-Za-z0-9_.-]+/)) {
        print "DELETE|" substr(s, RSTART, RLENGTH)
        exit
      }
      if (match(s, /alter[[:space:]]+table.{0,40}drop/)) {
        print "ALTER|" substr(s, RSTART, RLENGTH)
        exit
      }
      if (match(s, /drop[[:space:]]+function[[:space:]]+["`A-Za-z0-9_.-]+/)) {
        print "DROP|" substr(s, RSTART, RLENGTH)
        exit
      }
      if (match(s, /drop[[:space:]]+procedure[[:space:]]+["`A-Za-z0-9_.-]+/)) {
        print "DROP|" substr(s, RSTART, RLENGTH)
        exit
      }
    }
  ' <<EOF
$sql
EOF
}

target_from_hit() {
  printf '%s' "${1:-}" |
    sed -E 's/.*(database|schema|table|view|materialized[[:space:]]+view|from|function|procedure)[[:space:]]+(if[[:space:]]+exists[[:space:]]+)?["`]?([A-Za-z0-9_.-]+).*/\3/I'
}

is_relaxed_target() {
  local target
  target="$(printf '%s' "${1:-}" | tr -d '"`[]' | awk -F. '{print $NF}')"
  printf '%s' "$target" |
    grep -Eiq '^(tmp_|temp_|_tmp|_temp|_staging|_backup|_test)|(_tmp|_temp|_staging|_backup|_test)$'
}

is_create_if_not_exists() {
  printf '%s' "${1:-}" | grep -Eiq 'create[[:space:]]+table[[:space:]]+if[[:space:]]+not[[:space:]]+exists'
}

classify_sql() {
  local cli_tool="$1"
  local sql="$2"
  local session_id="$3"
  local hit verb hit_text target
  hit="$(detect_destructive "$sql")"
  if [ -z "$hit" ]; then
    audit "$session_id" "$cli_tool" "" "" "allow"
    return 0
  fi
  verb="${hit%%|*}"
  hit_text="${hit#*|}"
  target="$(target_from_hit "$hit_text")"
  if is_relaxed_target "$target" || is_create_if_not_exists "$sql"; then
    emit_warn "relaxed destructive SQL target" "$cli_tool" "$verb" "$target"
    audit "$session_id" "$cli_tool" "$verb" "$target" "warn"
    return 0
  fi
  emit_block "$cli_tool" "$verb" "$target"
  audit "$session_id" "$cli_tool" "$verb" "$target" "block"
  return 2
}

classify_file() {
  local cli_tool="$1"
  local file_path="$2"
  local cwd="$3"
  local session_id="$4"
  local sql rc
  sql="$(read_sql_file "$file_path" "$cwd")"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    emit_warn "SQL file does not exist yet" "$cli_tool" "" "$file_path"
    audit "$session_id" "$cli_tool" "" "$file_path" "warn"
    return 0
  fi
  classify_sql "$cli_tool" "$sql" "$session_id"
}

input="$(cat 2>/dev/null || printf '{}')"
if ! printf '%s' "$input" | jq empty >/dev/null 2>&1; then
  input='{}'
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // .toolName // .hook_event_name // ""')"
if [ "$tool_name" != "Bash" ]; then
  exit 0
fi

if [ "${CLAUDE_HOOK_BYPASS:-0}" = "1" ]; then
  session_id="$(printf '%s' "$input" | jq -r '.session_id // "unknown"')"
  audit "$session_id" "bypass" "" "" "allow_bypass"
  exit 0
fi

session_id="$(printf '%s' "$input" | jq -r '.session_id // "unknown"')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // .tool_input.cwd // empty')"
if [ -z "$cwd" ]; then
  cwd="$(pwd 2>/dev/null || printf '.')"
fi
command_text="$(printf '%s' "$input" | extract_command)"

decision=0

if printf '%s' "$command_text" | grep -Eiq 'databricks[[:space:]]+(sql|api).{0,50}--statement[[:space:]]*['"'"'"]?'; then
  sql="$(printf '%s' "$command_text" | sed -E 's/.*databricks[[:space:]]+(sql|api).{0,50}--statement[[:space:]]*['"'"'"]?//I')"
  classify_sql "databricks" "$sql" "$session_id" || decision=$?
elif printf '%s' "$command_text" | grep -Eiq 'databricks[[:space:]]+sql-cli[[:space:]]+.{0,40}--execute'; then
  sql="$(printf '%s' "$command_text" | sed -E 's/.*databricks[[:space:]]+sql-cli[[:space:]]+.{0,40}--execute[[:space:]]*['"'"'"]?//I')"
  classify_sql "databricks sql-cli" "$sql" "$session_id" || decision=$?
elif printf '%s' "$command_text" | grep -Eiq 'databricks(-cli)?[[:space:]].{0,80}(^|[[:space:]])-e[[:space:]]*['"'"'"]?'; then
  sql="$(printf '%s' "$command_text" | sed -E 's/.*databricks(-cli)?[[:space:]].{0,80}(^|[[:space:]])-e[[:space:]]*['"'"'"]?//I')"
  classify_sql "databricks" "$sql" "$session_id" || decision=$?
elif printf '%s' "$command_text" | grep -Eiq 'snowsql.{0,80}-q[[:space:]]*['"'"'"]?'; then
  sql="$(printf '%s' "$command_text" | sed -E 's/.*snowsql.{0,80}-q[[:space:]]*['"'"'"]?//I')"
  classify_sql "snowsql" "$sql" "$session_id" || decision=$?
elif printf '%s' "$command_text" | grep -Eiq 'snowsql.{0,80}-f[[:space:]]+[^[:space:]]+'; then
  file_path="$(printf '%s' "$command_text" | sed -E 's/.*snowsql.{0,80}-f[[:space:]]+([^[:space:]]+).*/\1/I')"
  classify_file "snowsql" "$file_path" "$cwd" "$session_id" || decision=$?
elif printf '%s' "$command_text" | grep -Eiq 'snow[[:space:]]+sql[[:space:]]+.{0,40}--query'; then
  sql="$(printf '%s' "$command_text" | sed -E 's/.*snow[[:space:]]+sql[[:space:]]+.{0,40}--query[[:space:]]*['"'"'"]?//I')"
  classify_sql "snow sql" "$sql" "$session_id" || decision=$?
elif printf '%s' "$command_text" | grep -Eiq 'psql.{0,80}(-c|--command)[[:space:]]+['"'"'"]?'; then
  sql="$(printf '%s' "$command_text" | sed -E 's/.*psql.{0,80}(-c|--command)[[:space:]]+['"'"'"]?//I')"
  classify_sql "psql" "$sql" "$session_id" || decision=$?
elif printf '%s' "$command_text" | grep -Eiq 'psql.{0,80}(-f|--file)[[:space:]]+[^[:space:]]+'; then
  file_path="$(printf '%s' "$command_text" | sed -E 's/.*psql.{0,80}(-f|--file)[[:space:]]+([^[:space:]]+).*/\2/I')"
  classify_file "psql" "$file_path" "$cwd" "$session_id" || decision=$?
elif printf '%s' "$command_text" | grep -Eiq 'bq[[:space:]]+query.{0,40}['"'"'"]?'; then
  sql="$(printf '%s' "$command_text" | sed -E 's/.*bq[[:space:]]+query.{0,40}['"'"'"]?//I')"
  classify_sql "bq query" "$sql" "$session_id" || decision=$?
elif printf '%s' "$command_text" | grep -Eiq 'bq[[:space:]]+rm[[:space:]]+(-f|-r)'; then
  emit_block "bq rm" "DROP" "bq resource"
  audit "$session_id" "bq rm" "DROP" "bq resource" "block"
  decision=2
elif printf '%s' "$command_text" | grep -Eiq 'aws[[:space:]]+redshift-data[[:space:]]+execute-statement.{0,80}--sql'; then
  sql="$(printf '%s' "$command_text" | sed -E 's/.*aws[[:space:]]+redshift-data[[:space:]]+execute-statement.{0,80}--sql[[:space:]]*['"'"'"]?//I')"
  classify_sql "aws redshift-data" "$sql" "$session_id" || decision=$?
else
  audit "$session_id" "none" "" "" "allow"
fi

if [ "$decision" -eq 2 ]; then
  exit 2
fi

if [ -n "$WARN_BUF" ]; then
  jq -n --arg ctx "$WARN_BUF" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: $ctx
    }
  }'
fi
exit 0
