#!/bin/bash
[ -S /tmp/cmux.sock ] || exit 0
EVENT=$(cat)
EVENT_TYPE=$(echo "$EVENT" | jq -r '.hook_event_name // "unknown"')
TOOL_NAME=$(echo "$EVENT" | jq -r '.tool_name // ""')
case "$EVENT_TYPE" in
  "Stop")
    cmux notify --title "Claude Code" --body "Session complete"
    ;;
  "PostToolUse")
    if [ "$TOOL_NAME" = "Task" ]; then
      cmux notify --title "Claude Code" --body "Subagent task complete"
    fi
    ;;
esac
exit 0
