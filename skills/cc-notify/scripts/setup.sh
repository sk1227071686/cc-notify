#!/bin/bash
# CC Notify - Setup wizard
# Guides the user through deploying WeCom DM notifications for Claude Code.

set -uo pipefail

CONFIG_DIR="$HOME/.claude/cc-notify"
CONFIG_PATH="$CONFIG_DIR/config.json"
TMP_CONFIG="$(mktemp)"

cleanup() {
  rm -f "$TMP_CONFIG"
}
trap cleanup EXIT

echo ""
echo "========================================="
echo "  CC Notify - WeCom DM Setup Wizard"
echo "========================================="
echo ""

# --- Auto-detect existing deployment status ---
detect_deployment() {
  # Step 1: Check config file exists
  if [ ! -f "$CONFIG_PATH" ]; then
    echo "NOT_DEPLOYED"
    return
  fi

  # Step 2: Validate config format
  if ! python3 "$SCRIPT_DIR/validate_config.py" >/dev/null 2>&1; then
    echo "INVALID_CONFIG"
    return
  fi

  # Step 3: Test proxy reachability
  local proxy_url
  proxy_url=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    print(json.load(f).get('proxy_url', ''))
" "$CONFIG_PATH" 2>/dev/null)

  if [ -z "$proxy_url" ]; then
    echo "INVALID_CONFIG"
    return
  fi

  local token_resp
  token_resp=$(curl -sk --connect-timeout 5 "${proxy_url}/cgi-bin/gettoken?corpid=$(python3 -c "import json;print(json.load(open(sys.argv[1]))['corpid'])" "$CONFIG_PATH")&corpsecret=$(python3 -c "import json;print(json.load(open(sys.argv[1]))['corpsecret'])" "$CONFIG_PATH")" 2>/dev/null || echo "{}")

  local access_token
  access_token=$(echo "$token_resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")

  if [ -z "$access_token" ]; then
    echo "PROXY_UNREACHABLE"
    return
  fi

  echo "DEPLOYED"
}

# --- Run auto-detect ---
echo ""
echo "Detecting existing deployment status..."
STATUS=$(detect_deployment)

case "$STATUS" in
  NOT_DEPLOYED)
    echo "No existing deployment found. Starting fresh setup..."
    ;;
  INVALID_CONFIG)
    echo "Existing config is invalid or corrupted."
    read -r -p "Reconfigure? [y/N] " answer </dev/tty
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
      echo "Setup cancelled."
      exit 0
    fi
    ;;
  PROXY_UNREACHABLE)
    echo "Config exists but proxy is unreachable."
    echo "Check your proxy server or enter new values."
    read -r -p "Reconfigure proxy settings? [y/N] " answer </dev/tty
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
      echo "Setup cancelled. Existing config kept."
      exit 0
    fi
    ;;
  DEPLOYED)
    echo "Existing deployment detected and working!"
    echo ""
    echo "Config: $CONFIG_PATH"
    echo "Proxy: $(python3 -c "import json;print(json.load(open(sys.argv[1]))['proxy_url'])" "$CONFIG_PATH")"
    echo "User: $(python3 -c "import json;print(json.load(open(sys.argv[1]))['userid'])" "$CONFIG_PATH")"
    echo ""
    read -r -p "Reconfigure anyway? [y/N] " answer </dev/tty
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
      echo "Setup cancelled. Existing deployment kept."
      exit 0
    fi
    ;;
esac

echo ""

# --- Helper: prompt with validation ---
prompt_required() {
  local var_name="$1"
  local prompt_text="$2"
  local silent="${3:-}"
  local value=""

  while [ -z "$value" ]; do
    if [ -n "$silent" ]; then
      read -rs -p "$prompt_text" value </dev/tty
      echo ""
    else
      read -r -p "$prompt_text" value </dev/tty
    fi
    value="$(echo "$value" | xargs)"
    if [ -z "$value" ]; then
      echo "  (required)"
    fi
  done

  printf '%s\n' "$value"
}

prompt_numeric() {
  local prompt_text="$1"
  local value=""

  while true; do
    read -r -p "$prompt_text" value </dev/tty
    value="$(echo "$value" | xargs)"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$value"
      return
    fi
    echo "  (must be a number)"
  done
}

prompt_proxy() {
  local prompt_text="$1"
  local value=""

  while true; do
    read -r -p "$prompt_text" value </dev/tty
    value="$(echo "$value" | xargs)"
    if [[ "$value" == https://* ]]; then
      printf '%s\n' "$value"
      return
    fi
    echo "  (must start with https://)"
  done
}

# --- Step-by-step collection ---
echo "Step 1/5: WeCom Corporate ID (corpid)"
echo "  Find it at: Admin Panel > Settings > Corporate Info > Corporate ID"
CORPID=$(prompt_required "corpid" "  Enter corpid: ")
echo ""

echo "Step 2/5: WeCom Application Secret (corpsecret)"
echo "  Create a self-built app at: Admin Panel > Application Management > Create App"
echo "  Then copy the Secret from the app details page"
CORPSECRET=$(prompt_required "corpsecret" "  Enter corpsecret: " "silent")
echo ""

echo "Step 3/5: WeCom Application ID (agentid)"
echo "  Find it at: Admin Panel > Application Management > [Your App] > AgentId"
AGENTID=$(prompt_numeric "  Enter agentid: ")
echo ""

echo "Step 4/5: Proxy Server URL"
echo "  Your public server needs an Nginx HTTPS reverse proxy to qyapi.weixin.qq.com"
echo "  See SKILL.md for proxy server setup instructions"
PROXY_URL=$(prompt_proxy "  Enter proxy URL (e.g., https://your-server.com:8443): ")
echo ""

echo "Step 5/5: Target User's WeCom UserID"
echo "  Find it at: Admin Panel > Contacts > [User] > UserID"
USERID=$(prompt_required "userid" "  Enter target userid: ")
echo ""

# --- Write config ---
echo "Writing configuration..."
mkdir -p "$CONFIG_DIR"

python3 -c "
import json, sys
config = {
    'corpid': sys.argv[1],
    'corpsecret': sys.argv[2],
    'agentid': sys.argv[3],
    'proxy_url': sys.argv[4],
    'userid': sys.argv[5]
}
with open(sys.argv[6], 'w') as f:
    json.dump(config, f, indent=2)
" "$CORPID" "$CORPSECRET" "$AGENTID" "$PROXY_URL" "$USERID" "$TMP_CONFIG"

chmod 600 "$TMP_CONFIG"
mv "$TMP_CONFIG" "$CONFIG_PATH"

echo ""
echo "Config saved to: $CONFIG_PATH"
echo ""

# --- Test connection ---
echo "Testing connection..."

TOKEN_RESP=$(curl -sk "${PROXY_URL}/cgi-bin/gettoken?corpid=${CORPID}&corpsecret=${CORPSECRET}" 2>/dev/null || echo "{}")
ACCESS_TOKEN=$(echo "$TOKEN_RESP" | python3 -c "
import sys
try:
    import json
    t = json.load(sys.stdin).get('access_token', '')
    print(t)
except:
    print('')
" 2>/dev/null || echo "")

if [ -z "$ACCESS_TOKEN" ]; then
  echo "[FAIL] Could not get access token. Common causes:"
  echo "  - corpid/corpsecret incorrect"
  echo "  - Proxy server not reachable from this machine"
  echo "  - Corporate trusted IP does not include this machine's egress IP"
  echo ""
  echo "  Fix the issue and re-run: bash $(dirname "$0")/setup.sh"
  exit 1
fi

echo "[OK] Access token obtained"

TEST_BODY="[Claude Code] Setup Test
Project: test
Reason: This is a test message from CC Notify"

curl -sk -X POST "${PROXY_URL}/cgi-bin/message/send?access_token=${ACCESS_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c "import json,sys; print(json.dumps({'touser':sys.argv[1],'msgtype':'text','agentid':int(sys.argv[2]),'text':{'content':sys.argv[3]}}))" "$USERID" "$AGENTID" "$TEST_BODY")" >/dev/null 2>&1

echo "[OK] Test message sent to $USERID"
echo ""

# --- Hook configuration ---
echo "========================================="
echo "  Setup Complete!"
echo "========================================="
echo ""

if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  echo "Plugin detected — hooks are already registered automatically."
  echo "No manual hook configuration needed."
else
  echo "Add the following hooks to your ~/.claude/settings.json:"
  echo ""
  cat <<'HOOKJSON'
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/notify.sh"
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt|idle_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/notify.sh"
          }
        ]
      }
    ]
  }
}
HOOKJSON
  echo ""
  echo "Then copy the hook script:"
  echo "  mkdir -p ~/.claude/hooks"
  echo "  cp $(dirname "$0")/notify.sh ~/.claude/hooks/notify.sh"
  echo "  chmod +x ~/.claude/hooks/notify.sh"
fi
echo ""
echo "Done! Your WeCom will notify you when Claude Code events fire."
echo ""
