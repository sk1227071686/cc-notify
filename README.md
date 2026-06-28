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

## Install as a plugin (recommended)

```bash
# Add the marketplace source
/plugin marketplace add sk1227071686/cc-notify

# Install the plugin
/plugin install cc-notify@cc-notify
```

The plugin automatically registers Stop/Notification hooks — no manual settings.json editing needed.

After installation, run the setup wizard:

```bash
bash ~/.claude/plugins/skills/cc-notify/scripts/setup.sh
```

## Install as a skill (legacy)

```bash
npx skills add sk1227071686/cc-notify
```

After installation, run the setup wizard to configure your credentials:

```bash
bash ~/.skills/cc-notify/scripts/setup.sh
```

> **Important:** Installing the skill does **not** enable automatic notifications. You must also configure the Claude Code hook to route `Stop` and `Notification` events to `notify.sh`. See the "Hook configuration" section below — without it, no notifications will be sent when events fire.

## Manual install

```bash
git clone https://github.com/sk1227071686/cc-notify.git
cd cc-notify
```

Copy the hook script:

```bash
mkdir -p ~/.claude/hooks
cp skills/cc-notify/scripts/notify.sh ~/.claude/hooks/notify.sh
chmod +x ~/.claude/hooks/notify.sh
```

Run the setup wizard:

```bash
bash skills/cc-notify/scripts/setup.sh
```

The wizard will collect all required credentials and test the notification chain.

Then add to `~/.claude/settings.json` (or use the plugin's built-in hooks):

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/notify.sh" }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt|idle_prompt",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/notify.sh" }
        ]
      }
    ]
  }
}
```

> **This step is required.** Without the hook configuration above, Claude Code will not call `notify.sh` when events fire, and no WeCom messages will be sent. The skill installation only places the script on disk — the hook must be explicitly registered in `settings.json`.

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
python3 <SKILL_DIR>/scripts/validate_config.py
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

```
[Claude Code] Task Done
Project: my-project
Reason: Task completed successfully
```

```
[Claude Code] Needs Permission
Project: my-project
Reason: Claude needs permission to run: rm -rf /tmp/build
```

```
[Claude Code] Idle
Project: my-project
Reason: Waiting for user input
```

## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| No notification at all | Config file missing | Run `bash setup.sh` |
| "Failed to get access token" | corpid/secret wrong or proxy unreachable | Check credentials and proxy URL |
| "not allow to access from your ip" | IP not in trusted IP list | Add your public server IP to WeCom trusted IP |
| "openapi callback URL request failed" | Callback server unreachable | Check Nginx + Python callback server |
| Test message succeeds but events don't notify | Hook not configured | Check `~/.claude/settings.json` hooks section |
| Message not delivered | User not in app visible range | Add user to app's visible range in WeCom admin |

## License

MIT
