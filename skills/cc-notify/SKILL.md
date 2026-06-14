---
name: cc-notify
description: >
  Desktop notification hook for Claude Code CLI on remote Linux hosts accessed via SSH.
  Triggers X11 popup windows (via xmessage) when CC tasks complete, need permission, or go idle.
  Use when: user mentions remote SSH development with CC, X11 forwarding, needing desktop alerts,
  wanting popup notifications for CC events, hooking CC Stop/Notification events, or the user says
  they can't notice when CC finishes tasks on a remote host.
  Also use when installing, configuring, or debugging CC hooks for visual notifications.
---

# CC Notify — Desktop popup notifications for Claude Code over SSH

When CC runs on a remote Linux host (accessed via SSH with X11 forwarding), you can't see it finish or ask for permission. This skill installs an X11 popup hook so events appear as desktop windows on your local machine.

## How it works

1. CC `Stop` / `Notification` hooks fire a shell script
2. The script calls `xmessage` which sends a window through X11 forwarding
3. The popup appears on your local desktop

## Prerequisites

- SSH with X11 forwarding enabled (`ssh -X` or `ssh -Y`)
- X11 server running on the local machine (MobaXterm, Xsrv, XQuartz, etc.)
- `xmessage` installed on the remote host (the skill will install it)

## Installation

### 1. Copy hook script to the remote host

```bash
mkdir -p ~/.claude/hooks
cp scripts/notify.sh ~/.claude/hooks/notify.sh
chmod +x ~/.claude/hooks/notify.sh
```

### 2. Install xmessage

```bash
sudo apt-get install -y x11-utils
```

### 3. Configure hooks in `~/.claude/settings.json`

Add a `hooks` key (merge with existing config):

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

### 4. Verify X11 works

```bash
echo $DISPLAY
xclock &
```

If you see a clock window on your local desktop, X11 forwarding is working.

## Notification events

| Event | Trigger | Popup title |
|---|---|---|
| `Stop` | CC finishes responding | "CC Task Done" |
| `Notification` + `permission_prompt` | CC needs permission to run a command | "CC Needs Permission" |
| `Notification` + `idle_prompt` | CC is idle, waiting for input | "CC Idle" |

## Troubleshooting

- **No popup**: Check `echo $DISPLAY` — if empty, X11 forwarding is not active. Reconnect with `ssh -Y`.
- **"xmessage: not found"**: Run `sudo apt-get install -y x11-utils`.
- **Chinese text garbled**: This is normal with MobaXterm — the hook uses English text to avoid encoding mismatches between Linux (UTF-8) and Windows X server (GBK).
- **Popups appear on wrong screen**: Set `DISPLAY` explicitly in the hook script.
