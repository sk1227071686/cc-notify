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

## First-time setup

Check if the skill is already configured:

```bash
test -f ~/.claude/cc-notify/config.json && echo "CONFIGURED" || echo "NEEDS_SETUP"
```

If `NEEDS_SETUP`, run the setup wizard:

```bash
bash <SKILL_DIR>/scripts/setup.sh
```

The wizard will guide you through:

1. **Getting corpid** — from WeCom Admin Panel > Settings > Corporate Info
2. **Getting corpsecret + agentid** — by creating a self-built app in Admin Panel > Application Management
3. **Setting up a proxy server** — Nginx HTTPS reverse proxy on a public server (see below)
4. **Configuring WeCom admin** — callback URL + trusted IP
5. **Getting target user's userid** — from Admin Panel > Contacts
6. **Testing** — sends a test message to verify the full chain

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

Add to `~/.claude/settings.json` (merge with existing config):

```json
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
```

Copy the hook script:

```bash
mkdir -p ~/.claude/hooks
cp <SKILL_DIR>/scripts/notify.sh ~/.claude/hooks/notify.sh
chmod +x ~/.claude/hooks/notify.sh
```

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
