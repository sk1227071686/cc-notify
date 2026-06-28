# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

CC Notify is a Claude Code hook (skill) that sends WeCom (Enterprise WeChat) direct messages when CC events fire on a remote Linux host. When Claude Code finishes a task, needs permission, or goes idle, a WeCom DM arrives on the user's phone/desktop.

## File structure

```
cc-notify/
  CLAUDE.md                          # This file - dev instructions
  README.md                          # User-facing documentation
  .claude/
    settings.json                    # Project-level hooks (commit to git for team sharing)
  .claude-plugin/
    plugin.json                      # Plugin manifest (for /plugin install)
  hooks/
    hooks.json                       # Plugin hooks config (auto-loaded on install)
    notify.sh                        # Hook script with auto-detection
  scripts/
    setup.sh                         # Interactive setup wizard with status detection
    validate_config.py               # Config validation helper
  skills/
    cc-notify/
      SKILL.md                       # Skill definition + setup guide
  docs/
    design.md                        # Design & implementation document
    deployment-guide.md              # Beginner deployment guide
    technical-decisions.md           # Technical decision records
    retrospective.md                 # Retrospective & lessons learned
```

## Installation methods

| Method | Best for | Hook auto-registration? |
|--------|----------|------------------------|
| Plugin (`/plugin install`) | Individual users | Yes — hooks.json auto-loads |
| Project-level `.claude/settings.json` | Teams | Yes — commit to git |
| Global `~/.claude/settings.json` | Personal all-projects | Manual setup required |

## Core architecture

### Hook script (`notify.sh`)

1. **Auto-detect**: Checks config exists, validates format, tests proxy reachability
2. Reads JSON from stdin (Claude Code hook standard input)
3. Parses `hook_event_name`, `notification_type`, `message`, `cwd` fields
4. Builds a notification message based on event type:
   - `Stop` → "[Claude Code] Task Done"
   - `Notification` + `permission_prompt` → "[Claude Code] Needs Permission"
   - `Notification` + `idle_prompt` → "[Claude Code] Idle"
5. Reads config from `~/.claude/cc-notify/config.json`
6. Gets access token via the proxy server
7. Sends WeCom DM via backgrounded curl (non-blocking)
8. Outputs `{}` (required by CC hooks)

### Setup wizard (`setup.sh`)

Interactive bash script with auto-detection:
1. Detects existing deployment status (NOT_DEPLOYED / INVALID_CONFIG / PROXY_UNREACHABLE / DEPLOYED)
2. Guides user accordingly (full setup / fix config / skip)
3. Collects and validates all 5 fields
4. Writes config atomically with backup of existing
5. Tests the full notification chain

### Config validation (`validate_config.py`)

Python3 script that validates `~/.claude/cc-notify/config.json`:
- All 5 required fields present
- `proxy_url` starts with `https://`
- `agentid` is numeric
- Exits 0 = valid, exit 1 = invalid

## Configuration

Users store credentials in `~/.claude/cc-notify/config.json` (mode 600):

```json
{
  "corpid": "wwxxxx",
  "corpsecret": "xxx",
  "agentid": "1000002",
  "proxy_url": "https://proxy:8443",
  "userid": "ZhangSan"
}
```

Hook config in `~/.claude/settings.json` routes Stop and Notification events to `notify.sh`.

## Proxy server architecture

The WeCom API requires requests from a trusted IP. Since the user's remote host may have a dynamic IP, a public server with a static IP acts as an HTTPS proxy:

```
notify.sh → proxy server (Nginx 8443) → qyapi.weixin.qq.com
```

The proxy server needs:
- Nginx with SSL, listening on port 8443
- Location `/callback/` → local Python server (handles WeCom URL validation)
- Location `/` → `https://qyapi.weixin.qq.com` (reverse proxy)
- Python callback server (pycryptodome dependency) on localhost:8444

## Development notes

- **No build/test tools**: Pure shell script + Markdown project, no build system or test framework.
- **No credentials in repo**: The distributed `notify.sh` contains NO credentials. All values come from `~/.claude/cc-notify/config.json`.
- **Graceful degradation**: The hook script always outputs `{}` even on errors, never blocking the CC pipeline.
- **Non-blocking**: The WeCom API call is backgrounded so it never delays CC.
- **Language**: Script uses English for code/comments; messages sent to WeCom may contain UTF-8 content from hook payloads.
- **Dependencies**: Only `python3`, `curl`, and `bash` on the user's machine. The proxy server needs `nginx` and `pycryptodome`.

## Development conventions

These conventions were derived from issues encountered during development. See `docs/retrospective.md` for full details.

### Hook script safety rules

1. **Never block the CC pipeline**: All exit paths must output `{}` to stdout before exiting
2. **Do not use `set -e`**: Use `set -uo pipefail` only; handle errors explicitly
3. **Errors go to stderr only**: stdout is reserved for the CC protocol `{}`
4. **Always exit 0**: Hook failures must not cause CC to error out
5. **Background network calls**: Any HTTP request must be non-blocking (backgrounded)

### Third-party API integration rules

1. **Read official docs first**: Especially for verification/signature/encryption flows — never guess
2. **Map the config dependency chain**: Understand A→B→C prerequisites before guiding users
3. **Use config files, never hardcode**: All credentials from external config
4. **Plan proxy path routing upfront**: Different backend services get different Nginx locations
