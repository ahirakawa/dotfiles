#!/usr/bin/env bash
set -uo pipefail

INPUT="$(cat)"

AUDIT_LOG="${HOME}/.claude/harness_audit.jsonl"
FILE_PATH=""

audit() {
  local decision="$1"
  local extra="$2"
  mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || true
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"ts":"%s","detector":"seed_pii_scan","decision":"%s","file":"%s",%s}\n' \
    "$ts" "$decision" "$FILE_PATH" "$extra" \
    >> "$AUDIT_LOG" 2>/dev/null || true
}

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
case "$TOOL_NAME" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')"
[ -z "$FILE_PATH" ] && exit 0

# Activation: case-insensitive seeds CSV/TSV check via POSIX ERE
LC_LOWER="$(printf '%s' "$FILE_PATH" | tr '[:upper:]' '[:lower:]')"
if ! printf '%s' "$LC_LOWER" | grep -Eq '(^|/)seeds/.*\.(csv|tsv)$'; then
  exit 0
fi

# Escape hatch
if [ "${CLAUDE_HOOK_BYPASS:-0}" = "1" ]; then
  audit "bypass" '"reason":"CLAUDE_HOOK_BYPASS=1"'
  exit 0
fi

# Extract content per tool
case "$TOOL_NAME" in
  Write)
    CONTENT="$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty')"
    ;;
  Edit)
    CONTENT="$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty')"
    ;;
  MultiEdit)
    CONTENT="$(printf '%s' "$INPUT" | jq -r '[.tool_input.edits[]?.new_string // empty] | join("\n")')"
    ;;
esac

if [ -z "${CONTENT:-}" ]; then
  audit "allow" '"reason":"empty_content"'
  exit 0
fi

TMP="$(mktemp -t pre_seed_pii.XXXXXX)"
trap 'rm -f "$TMP"' EXIT
printf '%s' "$CONTENT" > "$TMP"

PAT_EMAIL='[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'
PAT_US_PHONE='[0-9]{3}[-. ]?[0-9]{3,4}[-. ]?[0-9]{4}'
PAT_SSN='[0-9]{3}-[0-9]{2}-[0-9]{4}'
PAT_JP_PHONE='0[789]0[-. ]?[0-9]{4}[-. ]?[0-9]{4}'
PAT_CC='[0-9]{13,19}'

# CSV-like rows: lines containing >=2 commas
CSV_ROWS=$(grep -cE ',.*,' "$TMP" 2>/dev/null || true)
CSV_ROWS=${CSV_ROWS:-0}

lines_matching() {
  grep -nE "$1" "$TMP" 2>/dev/null | cut -d: -f1 | sort -un
}

EMAIL_LINES=$(lines_matching "$PAT_EMAIL")
US_PHONE_LINES=$(lines_matching "$PAT_US_PHONE")
SSN_LINES=$(lines_matching "$PAT_SSN")
JP_PHONE_LINES=$(lines_matching "$PAT_JP_PHONE")
CC_LINES=$(lines_matching "$PAT_CC")

EMAIL_COUNT=$(grep -oE "$PAT_EMAIL" "$TMP" 2>/dev/null | wc -l | tr -d ' ')
EMAIL_COUNT=${EMAIL_COUNT:-0}

is_in_list() {
  printf '%s\n' "$2" | grep -qx "$1"
}

ALL_MATCH_LINES=$(printf '%s\n%s\n%s\n%s\n%s\n' \
  "$EMAIL_LINES" "$US_PHONE_LINES" "$SSN_LINES" "$JP_PHONE_LINES" "$CC_LINES" \
  | grep -v '^$' | sort -un)

MULTI_TYPE_LINES=""
PII_LINES=""

for ln in $ALL_MATCH_LINES; do
  [ -z "$ln" ] && continue
  count=0
  has_noncc=0
  if is_in_list "$ln" "$EMAIL_LINES";    then count=$((count+1)); has_noncc=1; fi
  if is_in_list "$ln" "$US_PHONE_LINES"; then count=$((count+1)); has_noncc=1; fi
  if is_in_list "$ln" "$SSN_LINES";      then count=$((count+1)); has_noncc=1; fi
  if is_in_list "$ln" "$JP_PHONE_LINES"; then count=$((count+1)); has_noncc=1; fi
  if is_in_list "$ln" "$CC_LINES";       then count=$((count+1)); fi

  if [ "$has_noncc" -eq 1 ] || [ "$count" -ge 2 ]; then
    PII_LINES="$PII_LINES $ln"
  fi
  if [ "$count" -ge 2 ]; then
    MULTI_TYPE_LINES="$MULTI_TYPE_LINES $ln"
  fi
done

PII_LINES_UNIQ=$(printf '%s\n' $PII_LINES | grep -v '^$' | sort -un)
if [ -z "$PII_LINES_UNIQ" ]; then
  N=0
else
  N=$(printf '%s\n' "$PII_LINES_UNIQ" | wc -l | tr -d ' ')
fi

# Build matched type list (CC only included when combined)
TYPES=""
[ -n "$EMAIL_LINES" ]    && TYPES="${TYPES}email, "
[ -n "$US_PHONE_LINES" ] && TYPES="${TYPES}us_phone, "
[ -n "$SSN_LINES" ]      && TYPES="${TYPES}ssn, "
[ -n "$JP_PHONE_LINES" ] && TYPES="${TYPES}jp_phone, "
if [ -n "$CC_LINES" ] && [ -n "$MULTI_TYPE_LINES" ]; then
  TYPES="${TYPES}credit_card, "
fi
TYPES="${TYPES%, }"

first_lines() {
  printf '%s\n' "$1" | head -3 | paste -sd, -
}

emit_block() {
  local reason="$1"
  local first3
  first3=$(first_lines "$PII_LINES_UNIQ")
  local density="0%"
  if [ "$CSV_ROWS" -gt 0 ]; then
    density=$(awk -v n="$N" -v r="$CSV_ROWS" 'BEGIN{printf "%.0f%%", (n/r)*100}')
  fi
  {
    echo "[blocked] pre_seed_pii_scan: PII detected in seeds CSV"
    echo "  File: $FILE_PATH"
    echo "  Pattern: ${TYPES:-unknown} at lines: ${first3:-?}"
    echo "  Density: ${N}/${CSV_ROWS} rows (${density})"
    echo "  Reason: $reason"
    echo "  Bypass: CLAUDE_HOOK_BYPASS=1 claude"
  } >&2
  audit "block" "$(printf '"reason":"%s","csv_rows":%d,"pii_rows":%d,"emails":%d,"patterns":"%s"' \
    "$reason" "$CSV_ROWS" "$N" "$EMAIL_COUNT" "${TYPES:-}")"
  exit 2
}

# Rule 6: mass email leak
if [ "$EMAIL_COUNT" -gt 10 ]; then
  emit_block "mass_email_leak (>10 emails)"
fi

# Rule 5: any row with 2+ different PII types
if [ -n "$MULTI_TYPE_LINES" ]; then
  emit_block "multi_type_row (>=2 PII types on same row)"
fi

# Rule 4: density >30% across >=5 rows
if [ "$CSV_ROWS" -ge 5 ] && [ $((N * 10)) -gt $((CSV_ROWS * 3)) ]; then
  emit_block "high_density (>30% rows contain PII)"
fi

# Rule 7: warn-only if any PII present
if [ "$N" -gt 0 ]; then
  first3=$(first_lines "$PII_LINES_UNIQ")
  {
    echo "[warn] pre_seed_pii_scan: PII detected in seeds CSV (below block threshold)"
    echo "  File: $FILE_PATH"
    echo "  Pattern: ${TYPES:-unknown} at lines: ${first3:-?}"
    echo "  Density: ${N}/${CSV_ROWS} rows"
  } >&2
  audit "warn" "$(printf '"csv_rows":%d,"pii_rows":%d,"emails":%d,"patterns":"%s"' \
    "$CSV_ROWS" "$N" "$EMAIL_COUNT" "${TYPES:-}")"
  exit 0
fi

audit "allow" "$(printf '"csv_rows":%d' "$CSV_ROWS")"
exit 0
