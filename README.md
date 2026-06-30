# CC Notify

WeCom (Enterprise WeChat) DM notifications for Claude Code CLI on remote Linux hosts.

## Problem

When running Claude Code on a remote Linux host, you can't see when it finishes a task or needs permission — especially when you're away from your desk.

## Solution

A Claude Code hook that sends WeCom direct messages to your phone/desktop whenever CC events fire:

| Event | Trigger | Notification |
|---|---|---|
| `Stop` | Task completes | `[Claude Code] Task Done` |
| `permission_prompt` | Needs authorization | `[Claude Code] Needs Permission` |
| `idle_prompt` | Waiting for input | `[Claude Code] Idle` |

Each message includes the project name and the reason for the notification.

## Architecture

```
Claude Code hook
    |
    v
notify.sh (reads ~/.claude/cc-notify/config.json)
    |
    v
HTTPS proxy (your public server with static IP)
    |
    v
WeCom API (qyapi.weixin.qq.com)
    |
    v
WeCom DM on your phone
```

A public server with a static IP is required because WeCom API requires a trusted IP, and your remote host may have a dynamic IP. The public server runs an Nginx HTTPS reverse proxy that forwards requests to the WeCom API.

## Prerequisites

- WeCom (Enterprise WeChat) admin access
- A public server with a static IP (e.g., cloud VPS)
- Nginx with SSL certificate on the public server
- The target user must exist in your WeCom contacts

## Install via marketplace (recommended)

Install directly from the GitHub repository — no manual cloning needed:

```bash
# In Claude Code, add the marketplace source
/plugin marketplace add https://github.com/sk1227071686/cc-notify

# Install the plugin
/plugin install cc-notify@cc-notify
```

The plugin automatically registers `Stop` and `Notification` hooks — no `settings.json` editing needed.

After installation, run the setup wizard to configure your credentials:

```bash
bash ~/.claude/plugins/cc-notify/skills/cc-notify/scripts/setup.sh
```

The wizard will collect all required credentials and test the notification chain. Once configured, WeCom notifications will fire automatically when Claude Code events occur.

## Manual install

Clone the repository and run setup:

```bash
git clone https://github.com/sk1227071686/cc-notify.git
cd cc-notify
bash skills/cc-notify/scripts/setup.sh
```

Then add to `~/.claude/settings.json` to register the hooks:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "bash \"/path/to/cc-notify/hooks/notify.sh\"" }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt|idle_prompt",
        "hooks": [
          { "type": "command", "command": "bash \"/path/to/cc-notify/hooks/notify.sh\"" }
        ]
      }
    ]
  }
}
```

> **This step is required.** Without the hook configuration above, Claude Code will not call `notify.sh` when events fire. Replace `/path/to/cc-notify` with the actual clone path.

## Configuration file

The setup wizard creates `~/.claude/cc-notify/config.json`:

```json
{
  "corpid": "wwxxxxxxxxxxxxxxxx",
  "corpsecret": "your-app-secret",
  "agentid": "1000002",
  "proxy_url": "https://your-proxy-server.com:8443",
  "userid": "ZhangSan"
}
```

Validate it anytime:

```bash
# If installed via marketplace:
python3 ~/.claude/plugins/cc-notify/skills/cc-notify/scripts/validate_config.py

# If installed manually:
python3 /path/to/cc-notify/skills/cc-notify/scripts/validate_config.py
```

## Proxy server setup

See the SKILL.md for detailed proxy server setup instructions (Nginx + Python callback server).

Quick summary:
1. Install Nginx on your public server with SSL
2. Configure Nginx to proxy `/` → `qyapi.weixin.qq.com` and `/callback/` → local Python server
3. Set up the Python callback server (handles WeCom URL validation)
4. Add your public server IP to WeCom admin as trusted IP
5. Configure the callback URL in WeCom admin

## Notification format

Messages are sent as Enterprise WeChat **markdown** with emoji:

```
**✅ Claude Code — Task Done**
📁 `my-project`
📝 Task completed successfully
```

```
**🔔 Claude Code — Needs Permission**
📁 `my-project`
📝 Waiting for permission to proceed
```

```
**⏸️ Claude Code — Idle**
📁 `my-project`
📝 Waiting for user input
```

## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| No notification at all | Config file missing | Run `bash ~/.claude/plugins/cc-notify/skills/cc-notify/scripts/setup.sh` |
| "Failed to get access token" | corpid/secret wrong or proxy unreachable | Check credentials and proxy URL |
| "not allow to access from your ip" | IP not in trusted IP list | Add your public server IP to WeCom trusted IP |
| "openapi callback URL request failed" | Callback server unreachable | Check Nginx + Python callback server |
| Test message succeeds but events don't notify | Hook not configured | Check `~/.claude/settings.json` hooks section |
| Message not delivered | User not in app visible range | Add user to app's visible range in WeCom admin |

## License

MIT
