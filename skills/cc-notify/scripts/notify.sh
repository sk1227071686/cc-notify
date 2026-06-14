#!/bin/bash
# CC Notify - Claude Code notification hook
# Shows X11 popup via xmessage when CC events fire.
# Uses English to avoid encoding issues with MobaXterm X11 on Windows.

set -euo pipefail

INPUT=$(cat)

EVENT_TYPE=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('hook_event_name', ''))
" 2>/dev/null || echo "")

NOTIFICATION_TYPE=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('notification_type', ''))
" 2>/dev/null || echo "")

MESSAGE=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('message', ''))
" 2>/dev/null || echo "")

CWD=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('cwd', ''))
" 2>/dev/null || echo "")

PROJECT=$(basename "$CWD" 2>/dev/null || echo "unknown")

# Build notification based on event type
case "$EVENT_TYPE" in
  Stop)
    TITLE="CC Task Done"
    BODY="Project: $PROJECT"
    ;;
  Notification)
    case "$NOTIFICATION_TYPE" in
      permission_prompt)
        TITLE="CC Needs Permission"
        BODY="Project: $PROJECT"
        ;;
      idle_prompt)
        TITLE="CC Idle"
        BODY="Project: $PROJECT — waiting for input"
        ;;
      *)
        TITLE="CC Notification"
        BODY="Project: $PROJECT"
        ;;
    esac
    ;;
  *)
    TITLE="CC Event"
    BODY="$EVENT_TYPE — $PROJECT"
    ;;
esac

# Show X11 popup (non-blocking)
export DISPLAY="${DISPLAY:-localhost:11.0}"
xmessage -center -buttons "OK:0" -default "OK" \
  "$TITLE

$BODY" 2>/dev/null &

# Output empty JSON (required by CC hooks)
echo "{}"
