#!/bin/bash
[ -S /tmp/cmux.sock ] || exit 0
EVENT=$(cat)
EVENT_TYPE=$(echo "$EVENT" | jq -r '.event // "unknown"')
case "$EVENT_TYPE" in
  "Stop")
    cmux notify --title "Claude Code" --body "Session complete"
    ;;
esac
