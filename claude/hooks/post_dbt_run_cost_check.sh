#!/usr/bin/env bash
set -uo pipefail

INPUT=$(cat)

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')

if ! printf '%s' "$COMMAND" | grep -E -q 'dbt[[:space:]]+(run|build)\b'; then
  exit 0
fi

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
[ -z "$CWD" ] && CWD="$PWD"

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"')

RUN_RESULTS=""
for candidate in "$CWD/target/run_results.json" "$CWD/dbt/target/run_results.json"; do
  if [ -f "$candidate" ]; then
    RUN_RESULTS="$candidate"
    break
  fi
done

[ -z "$RUN_RESULTS" ] && exit 0

if ! jq empty "$RUN_RESULTS" 2>/dev/null; then
  printf '[warn] dbt_cost_check: malformed run_results.json at %s\n' "$RUN_RESULTS" >&2
  exit 0
fi

DBU_RATE="${DBT_DBU_RATE_USD:-0.40}"
WARN_THRESHOLD="${DBT_COST_WARN_USD:-1.0}"
TOTAL_THRESHOLD="${DBT_COST_TOTAL_USD:-10.0}"

RESULTS_TSV=$(jq -r --arg rate "$DBU_RATE" '
  .results[]?
  | select(.status != "skipped")
  | [
      ((.execution_time // 0) / 3600 * ($rate | tonumber)),
      (.execution_time // 0),
      (.unique_id // "unknown")
    ]
  | @tsv
' "$RUN_RESULTS")

if [ -z "$RESULTS_TSV" ]; then
  exit 0
fi

TOTAL_COUNT=$(printf '%s\n' "$RESULTS_TSV" | wc -l | tr -d ' ')
TOTAL_COST=$(printf '%s\n' "$RESULTS_TSV" | awk -F'\t' '{s+=$1} END {printf "%.4f", s+0}')

WARN_TSV=$(printf '%s\n' "$RESULTS_TSV" \
  | awk -F'\t' -v t="$WARN_THRESHOLD" '($1+0) > (t+0)' \
  | sort -t$'\t' -k1,1 -rn)

if [ -z "$WARN_TSV" ]; then
  WARN_COUNT=0
else
  WARN_COUNT=$(printf '%s\n' "$WARN_TSV" | wc -l | tr -d ' ')
fi

TOTAL_OVER=$(awk -v t="$TOTAL_COST" -v th="$TOTAL_THRESHOLD" \
  'BEGIN { print ((t+0) > (th+0)) ? 1 : 0 }')

if [ "$WARN_COUNT" -eq 0 ] && [ "$TOTAL_OVER" -eq 0 ]; then
  exit 0
fi

TOP_LINE=$(printf '%s\n' "$RESULTS_TSV" | sort -t$'\t' -k1,1 -rn | head -n1)
TOP_COST=$(printf '%s' "$TOP_LINE" | cut -f1)
TOP_MODEL=$(printf '%s' "$TOP_LINE" | cut -f3)

MD=$(
  if [ "$TOTAL_OVER" -eq 1 ]; then
    printf '> **[HIGH]** Total run cost $%.2f exceeds threshold $%.2f\n\n' \
      "$TOTAL_COST" "$TOTAL_THRESHOLD"
  fi
  printf '## dbt cost summary\n\n'
  printf 'Total estimated cost: **$%.2f** across %s model(s) (DBU rate: $%s/hr)\n\n' \
    "$TOTAL_COST" "$TOTAL_COUNT" "$DBU_RATE"
  if [ "$WARN_COUNT" -gt 0 ]; then
    printf 'Models exceeding per-model threshold ($%.2f):\n\n' "$WARN_THRESHOLD"
    printf '| Model | Time(s) | Estimated Cost |\n|---|---:|---:|\n'
    printf '%s\n' "$WARN_TSV" \
      | awk -F'\t' '{ printf "| %s | %.2f | $%.2f |\n", $3, $2, $1 }'
  fi
)

jq -nc --arg ctx "$MD" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'

AUDIT_DIR="$HOME/.claude"
mkdir -p "$AUDIT_DIR" 2>/dev/null || true

jq -nc \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg detector "dbt_cost_check" \
  --arg session_id "$SESSION_ID" \
  --argjson total_models "$TOTAL_COUNT" \
  --argjson total_cost_usd "$TOTAL_COST" \
  --argjson warned_count "$WARN_COUNT" \
  --arg top_model "$TOP_MODEL" \
  --argjson top_cost_usd "$TOP_COST" \
  '{
    ts: $ts,
    detector: $detector,
    session_id: $session_id,
    total_models: $total_models,
    total_cost_usd: $total_cost_usd,
    warned_count: $warned_count,
    top_model: $top_model,
    top_cost_usd: $top_cost_usd
  }' \
  >> "$AUDIT_DIR/harness_audit.jsonl" 2>/dev/null || true

exit 0
