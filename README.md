# CC Notify

Desktop popup notifications for Claude Code CLI on remote Linux hosts accessed via SSH with X11 forwarding.

## Problem

When running Claude Code on a remote Linux host via SSH, you can't see when it finishes a task or needs permission — especially when you're focused on other windows.

## Solution

A Claude Code hook that triggers X11 popup windows (via `xmessage`) on your local desktop whenever CC events fire:

| Event | Trigger | Popup |
|---|---|---|
| `Stop` | Task completes | "CC Task Done" |
| `permission_prompt` | Needs authorization | "CC Needs Permission" |
| `idle_prompt` | Waiting for input | "CC Idle" |

## Install as a skill

```bash
npx skills add sk1227071686/cc-notify
```

## Manual install

```bash
git clone https://github.com/sk1227071686/cc-notify.git
cd cc-notify
cp -r skills/cc-notify ~/.skills/
mkdir -p ~/.claude/hooks
cp skills/cc-notify/scripts/notify.sh ~/.claude/hooks/notify.sh
chmod +x ~/.claude/hooks/notify.sh
sudo apt-get install -y x11-utils
```

Then add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/notify.sh" }] }],
    "Notification": [{ "matcher": "permission_prompt|idle_prompt", "hooks": [{ "type": "command", "command": "~/.claude/hooks/notify.sh" }] }]
  }
}
```

## Prerequisites

- SSH with X11 forwarding: `ssh -Y user@host`
- X11 server on local machine (MobaXterm, XQuartz, Xsrv, etc.)
- Tested with MobaXterm on Windows

## License

MIT
