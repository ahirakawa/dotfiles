#!/usr/bin/env bash
set -uo pipefail

AUDIT_LOG="${HOME}/.claude/harness_audit.jsonl"
mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || true

input="$(cat)"

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
if [[ "$tool_name" != "Bash" ]]; then
  exit 0
fi

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
if [[ -z "$cmd" ]]; then
  exit 0
fi

session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

json_escape() {
  printf '%s' "$1" | jq -Rs .
}

command_summary="${cmd:0:80}"

audit() {
  local decision="$1" target="$2" reason="$3"
  local line
  line="$(jq -cn \
    --arg ts "$ts" \
    --arg event "PreToolUse" \
    --arg detector "dbt_target_guard" \
    --arg session_id "$session_id" \
    --arg decision "$decision" \
    --arg target "$target" \
    --arg command_summary "$command_summary" \
    --arg reason "$reason" \
    '{ts:$ts, event:$event, detector:$detector, session_id:$session_id, decision:$decision, target:$target, command_summary:$command_summary, reason:$reason}')"
  printf '%s\n' "$line" >> "$AUDIT_LOG" 2>/dev/null || true
}

# Non-blocking warnings are collected and delivered via additionalContext at
# the end (stderr at exit 0 never reaches Claude).
WARN_BUF=""
add_warn() {
  local line="[dbt-target warning] $1"
  if [[ -z "$WARN_BUF" ]]; then
    WARN_BUF="$line"
  else
    WARN_BUF="${WARN_BUF}
${line}"
  fi
}

# Escape hatch
if [[ "${CLAUDE_HOOK_BYPASS:-0}" == "1" ]]; then
  if printf '%s' "$cmd" | grep -Eqi '(^|[[:space:];&|])dbt[[:space:]]'; then
    printf '[bypass] pre_dbt_target_guard: CLAUDE_HOOK_BYPASS=1 set, skipping dbt target checks.\n' >&2
    audit "bypassed" "" "CLAUDE_HOOK_BYPASS=1"
  fi
  exit 0
fi

# Only act on dbt invocations
if ! printf '%s' "$cmd" | grep -Eqi '(^|[[:space:];&|`(])dbt([[:space:]]|$)'; then
  exit 0
fi

# Extract dbt subcommand (first word after `dbt`)
dbt_sub="$(printf '%s' "$cmd" | grep -Eoi 'dbt[[:space:]]+[a-z][a-z-]*' | head -n1 | awk '{print tolower($2)}')"

is_write_sub=0
case "$dbt_sub" in
  run|build|seed|snapshot|run-operation) is_write_sub=1 ;;
esac

# Extract --target / -t value (best-effort)
target_val=""
if printf '%s' "$cmd" | grep -Eqi -- '(--target|--target=|[[:space:]]-t)[[:space:]=]'; then
  target_val="$(printf '%s' "$cmd" \
    | grep -Eoi -- '(--target[[:space:]=]+[a-z0-9_-]+|[[:space:]]-t[[:space:]]+[a-z0-9_-]+)' \
    | head -n1 \
    | sed -E 's/.*(--target[[:space:]=]+|[[:space:]]-t[[:space:]]+)//I' \
    | tr '[:upper:]' '[:lower:]')"
fi

# DBT_TARGET=... env var prefix
env_target=""
if printf '%s' "$cmd" | grep -Eqi '(^|[[:space:];&|])DBT_TARGET='; then
  env_target="$(printf '%s' "$cmd" \
    | grep -Eoi 'DBT_TARGET=[a-z0-9_-]+' \
    | head -n1 \
    | sed -E 's/^DBT_TARGET=//I' \
    | tr '[:upper:]' '[:lower:]')"
fi

is_prod_target=0
prod_reason=""
if [[ "$target_val" == "prod" || "$target_val" == "production" ]]; then
  is_prod_target=1
  prod_reason="--target ${target_val}"
elif [[ "$env_target" == "prod" || "$env_target" == "production" ]]; then
  is_prod_target=1
  prod_reason="DBT_TARGET=${env_target}"
fi

# BLOCK: write-subcommand against prod
if [[ "$is_write_sub" -eq 1 && "$is_prod_target" -eq 1 ]]; then
  effective_target="${target_val:-$env_target}"
  reason="dbt ${dbt_sub} with ${prod_reason}"
  audit "blocked" "$effective_target" "$reason"
  {
    printf '[blocked] pre_dbt_target_guard: dbt against production target.\n'
    printf '  Reason: %s\n' "$reason"
    printf '  Bypass: start Claude Code with CLAUDE_HOOK_BYPASS=1 claude\n'
    printf '  Or run the command outside auto mode in your own terminal.\n'
  } >&2
  exit 2
fi

# WARN: --full-refresh against prod (defensive — should already be blocked above, but cover edge)
if [[ "$is_prod_target" -eq 1 ]] && printf '%s' "$cmd" | grep -Eqi -- '(^|[[:space:]])--full-refresh([[:space:]]|$)'; then
  audit "warned" "${target_val:-$env_target}" "--full-refresh against prod"
  add_warn "--full-refresh against production target."
fi

# WARN: dbt write-subcommand without explicit --target (uses profile default)
if [[ "$is_write_sub" -eq 1 && -z "$target_val" && -z "$env_target" ]]; then
  audit "warned" "" "dbt ${dbt_sub} without explicit --target (profile default)"
  add_warn "dbt ${dbt_sub} without explicit --target; profile default will be used."
fi

# WARN: dbt seed --full-refresh
if [[ "$dbt_sub" == "seed" ]] && printf '%s' "$cmd" | grep -Eqi -- '(^|[[:space:]])--full-refresh([[:space:]]|$)'; then
  audit "warned" "${target_val:-$env_target}" "dbt seed --full-refresh"
  add_warn "dbt seed --full-refresh will reload all seed data."
fi

if [[ -n "$WARN_BUF" ]]; then
  jq -n --arg ctx "$WARN_BUF" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: $ctx
    }
  }'
fi

exit 0
