#!/bin/bash
# CC Notify - Claude Code notification hook
# Sends WeCom (Enterprise WeChat) DM notification when CC events fire.
# Reads configuration from ~/.claude/cc-notify/config.json

set -uo pipefail

CONFIG_PATH="$HOME/.claude/cc-notify/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Load configuration ---
load_config() {
  if [ ! -f "$CONFIG_PATH" ]; then
    echo "[cc-notify] Config not found at $CONFIG_PATH" >&2
    echo "[cc-notify] Run: bash $SCRIPT_DIR/setup.sh" >&2
    return 1
  fi

  local parsed
  parsed=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    required = ['corpid', 'corpsecret', 'agentid', 'proxy_url', 'userid']
    for k in required:
        v = d.get(k, '')
        if not v:
            print(f'MISSING:{k}', file=sys.stderr)
            sys.exit(1)
    if not d['proxy_url'].startswith('https://'):
        print('BAD_PROXY', file=sys.stderr)
        sys.exit(1)
    if not d['agentid'].isdigit():
        print('BAD_AGENTID', file=sys.stderr)
        sys.exit(1)
    print(d['corpid'], d['corpsecret'], d['agentid'], d['proxy_url'], d['userid'])
except Exception as e:
    print(f'ERROR:{e}', file=sys.stderr)
    sys.exit(1)
" "$CONFIG_PATH" 2>/dev/null) || return 1

  read -r CORPID CORPSECRET AGENT_ID PROXY_URL USER_ID <<< "$parsed"
  return 0
}

# --- Parse stdin JSON ---
INPUT=$(cat)

EVENT_TYPE=$(echo "$INPUT" | python3 -c "
import sys
try:
    import json
    d = json.load(sys.stdin)
    print(d.get('hook_event_name', ''))
except:
    print('')
" 2>/dev/null || echo "")

NOTIFICATION_TYPE=$(echo "$INPUT" | python3 -c "
import sys
try:
    import json
    d = json.load(sys.stdin)
    print(d.get('notification_type', ''))
except:
    print('')
" 2>/dev/null || echo "")

MESSAGE=$(echo "$INPUT" | python3 -c "
import sys
try:
    import json
    d = json.load(sys.stdin)
    print(d.get('message', ''))
except:
    print('')
" 2>/dev/null || echo "")

CWD=$(echo "$INPUT" | python3 -c "
import sys
try:
    import json
    d = json.load(sys.stdin)
    print(d.get('cwd', ''))
except:
    print('')
" 2>/dev/null || echo "")

PROJECT=$(basename "$CWD" 2>/dev/null || echo "unknown")

# --- Build notification content ---
case "$EVENT_TYPE" in
  Stop)
    TITLE="Task Done"
    REASON="${MESSAGE:-Task completed successfully}"
    ;;
  Notification)
    case "$NOTIFICATION_TYPE" in
      permission_prompt)
        TITLE="Needs Permission"
        REASON="${MESSAGE:-Waiting for permission to proceed}"
        ;;
      idle_prompt)
        TITLE="Idle"
        REASON="${MESSAGE:-Waiting for user input}"
        ;;
      *)
        TITLE="Notification"
        REASON="${MESSAGE:-$NOTIFICATION_TYPE}"
        ;;
    esac
    ;;
  *)
    TITLE="Event"
    REASON="${MESSAGE:-$EVENT_TYPE}"
    ;;
esac

FULL_BODY="[Claude Code] ${TITLE}
Project: ${PROJECT}
Reason: ${REASON}"

# --- Load config and send ---
if ! load_config; then
  echo "{}"
  exit 0
fi

# Get access token
TOKEN_RESP=$(curl -sk "${PROXY_URL}/cgi-bin/gettoken?corpid=${CORPID}&corpsecret=${CORPSECRET}" 2>/dev/null || echo "{}")
ACCESS_TOKEN=$(echo "$TOKEN_RESP" | python3 -c "
import sys
try:
    import json
    print(json.load(sys.stdin).get('access_token', ''))
except:
    print('')
" 2>/dev/null || echo "")

if [ -z "$ACCESS_TOKEN" ]; then
  echo "[cc-notify] Failed to get access token" >&2
  echo "{}"
  exit 0
fi

# Build payload and send (non-blocking)
python3 -c "
import json, subprocess, sys

payload = {
    'touser': sys.argv[1],
    'msgtype': 'text',
    'agentid': int(sys.argv[2]),
    'text': {'content': sys.argv[3]}
}

cmd = [
    'curl', '-sk', '-X', 'POST',
    sys.argv[4] + '/cgi-bin/message/send?access_token=' + sys.argv[5],
    '-H', 'Content-Type: application/json',
    '-d', json.dumps(payload)
]

subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
" "$USER_ID" "$AGENT_ID" "$FULL_BODY" "$PROXY_URL" "$ACCESS_TOKEN" 2>/dev/null &

# Output empty JSON (required by CC hooks)
echo "{}"
