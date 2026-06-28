---
name: cc-notify
description: >
  WeCom (Enterprise WeChat) DM notifications for Claude Code CLI.
  Sends a WeCom direct message when CC tasks complete, need permission, or go idle.
  Use when: user mentions WeCom notifications for CC, wanting DM alerts for CC events,
  hooking CC Stop/Notification events to WeCom, setting up CC notifications,
  or the user wants to know when CC finishes tasks on a remote host.
  Also use when installing, configuring, or debugging CC hooks for WeCom notifications.
---

# CC Notify — WeCom DM notifications for Claude Code

When CC runs on a remote Linux host, you can't see it finish or ask for permission. This skill sends WeCom (Enterprise WeChat) direct messages to your phone/desktop when CC events fire.

## How it works

1. CC `Stop` / `Notification` hooks fire a shell script
2. The script calls the WeCom API via a public server HTTPS proxy
3. A WeCom DM arrives on your phone with the event details

## Installation

### Method 1: Plugin (recommended for individual users)

```bash
# Add the marketplace source (this project's GitHub repo)
/plugin marketplace add sk1227071686/cc-notify

# Install the plugin
/plugin install cc-notify@cc-notify
```

The plugin automatically registers Stop/Notification hooks — no manual `settings.json` editing needed.

After installation, run the setup wizard:

```bash
bash <SKILL_DIR>/scripts/setup.sh
```

### Method 2: Project-level hooks (recommended for teams)

If you work on a team, commit the hooks to your project repo:

1. Copy the project's `.claude/settings.json` to your project root
2. Copy `hooks/notify.sh` to `.claude/hooks/notify.sh` (or install globally)
3. Commit these files to git

Anyone who clones the project gets hooks automatically.

### Method 3: Global hooks (personal use across all projects)

Copy `notify.sh` to `~/.claude/hooks/notify.sh` and add the hook config to `~/.claude/settings.json`.

## First-time setup

The setup wizard auto-detects your current deployment status:

```bash
bash <SKILL_DIR>/scripts/setup.sh
```

It will tell you if:
- ✅ Already deployed and working — no action needed
- ❌ Config missing — guides you through full setup
- ⚠️ Config exists but proxy unreachable — offers to reconfigure

You can also check manually:

```bash
test -f ~/.claude/cc-notify/config.json && echo "CONFIGURED" || echo "NEEDS_SETUP"
```

## Manual setup

If you prefer manual configuration, create `~/.claude/cc-notify/config.json`:

```json
{
  "corpid": "wwxxxxxxxxxxxxxxxx",
  "corpsecret": "your-app-secret",
  "agentid": "1000002",
  "proxy_url": "https://your-proxy-server.com:8443",
  "userid": "ZhangSan"
}
```

Then validate it:

```bash
python3 <SKILL_DIR>/scripts/validate_config.py
```

## Hook configuration

> **This step is required for automatic notifications.** Installing the skill only places `notify.sh` on disk. Claude Code will not call it on `Stop`/`Notification` events unless you register the hook. Without this configuration, no WeCom messages will be sent when events fire.

### For Plugin installation (Method 1)

Hooks are automatically registered. No manual configuration needed.

### For Project-level installation (Method 2)

Add to your project's `.claude/settings.json` (merge with existing config):

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/notify.sh\"",
            "timeout": 30,
            "async": true
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
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/notify.sh\"",
            "timeout": 30,
            "async": true
          }
        ]
      }
    ]
  }
}
```

### For Global installation (Method 3)

Copy `notify.sh` to `~/.claude/hooks/notify.sh` and add the same hook config to `~/.claude/settings.json`.

## Notification format

Messages sent to WeCom look like:

```
[Claude Code] Task Done
Project: my-project
Reason: Task completed successfully
```

```
[Claude Code] Needs Permission
Project: my-project
Reason: Waiting for permission to proceed
```

```
[Claude Code] Idle
Project: my-project
Reason: Waiting for user input
```

## Proxy server setup

The WeCom API requires requests to come from a trusted IP. Since your remote host may have a dynamic IP, a public server with a static IP acts as an HTTPS proxy.

### Nginx configuration (on your public server)

```nginx
server {
    listen 8443 ssl;
    server_name your-domain.com;

    ssl_certificate     /path/to/fullchain.pem;
    ssl_certificate_key /path/to/private.key;

    # Callback verification (for WeCom admin panel URL validation)
    location /callback/ {
        proxy_pass http://127.0.0.1:8444;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # All other requests -> WeCom API
    location / {
        proxy_pass https://qyapi.weixin.qq.com;
        proxy_ssl_server_name on;
        proxy_set_header Host qyapi.weixin.qq.com;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

### Callback verification server (Python)

Save as `/opt/wecom-callback/server.py` on your public server:

```python
#!/usr/bin/env python3
import os, base64, struct
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from Crypto.Cipher import AES

TOKEN = "YOUR_TOKEN_FROM_WECOM_ADMIN"
ENCODING_AES_KEY = "YOUR_AES_KEY_FROM_WECOM_ADMIN"
LISTEN_PORT = 8444

class WeComHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        params = parse_qs(urlparse(self.path).query)
        echostr = params.get("echostr", [""])[0]
        if not echostr:
            self.send_error(400)
            return
        try:
            aes_key = base64.b64decode(ENCODING_AES_KEY + "=")
            cipher = AES.new(aes_key, AES.MODE_CBC, aes_key[:16])
            decrypted = cipher.decrypt(base64.b64decode(echostr))
            pad = decrypted[-1]
            decrypted = decrypted[:-pad]
            msg_len = struct.unpack(">I", decrypted[16:20])[0]
            msg = decrypted[20:20 + msg_len].decode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(msg.encode("utf-8"))
        except Exception:
            self.send_error(500)

    def do_POST(self):
        cl = int(self.headers.get("Content-Length", 0))
        self.rfile.read(cl)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"success")

    def log_message(self, format, *args):
        pass

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", LISTEN_PORT), WeComHandler)
    server.serve_forever()
```

Install dependency: `pip3 install pycryptodome`

Run: `python3 /opt/wecom-callback/server.py &`

### WeCom admin panel configuration

1. Go to your app in Admin Panel > Application Management
2. Find "Receive Message" > "Set API Receive"
3. URL: `https://your-domain.com:8443/callback/<your-agentid>`
4. Token / EncodingAESKey: same as in the Python script
5. Encryption mode: plaintext
6. Save, then add your public server IP to "Corporate Trusted IP"

## Troubleshooting

- **No notification**: Check `~/.claude/cc-notify/config.json` exists and is valid
- **"Failed to get access token"**: corpid/corpsecret wrong, or proxy unreachable
- **"not allow to access from your ip"**: public server IP not in WeCom trusted IP list
- **"openapi callback URL request failed"**: callback server not running or not reachable from WeCom
- **Message not delivered**: target user not in app's visible range in WeCom admin
