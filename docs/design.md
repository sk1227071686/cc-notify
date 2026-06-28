# CC Notify — Design & Implementation Document

## 1. Requirements

### 1.1 Problem Statement

When running Claude Code (CC) on a remote Linux host via SSH, users cannot notice when CC finishes a task, needs permission, or goes idle. The previous solution (X11 popup via `xmessage`) was ineffective because:

- X11 popups only appear on the local desktop; users miss them when away
- Popups disappear after timeout; no persistent record
- Requires X11 forwarding setup (complex, fragile, encoding issues)
- Not actionable from a phone

### 1.2 Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| R1 | Send notification to user's phone when CC events fire | Must |
| R2 | Support Stop, permission_prompt, idle_prompt events | Must |
| R3 | Notification must include [Claude Code] label, project name, and event reason | Must |
| R4 | Auto-detect deployment status; guide setup if not configured | Must |
| R5 | Never block the CC pipeline (graceful degradation) | Must |
| R6 | Generic distribution — no hardcoded credentials in repo | Must |
| R7 | Support users behind dynamic IP via public server proxy | Should |
| R8 | Interactive setup wizard for first-time deployment | Should |

### 1.3 Constraints

- Shell script only on user's machine (no new runtime dependencies beyond python3 + curl)
- WeCom API requires requests from a trusted IP (static)
- Users on remote hosts typically have dynamic IPs
- CC hook protocol requires stdout output of `{}`

## 2. Design

### 2.1 Architecture

```
Claude Code
    |
    | (hook event: Stop / Notification)
    v
notify.sh (on user's machine)
    |
    | 1. Read ~/.claude/cc-notify/config.json
    | 2. Parse hook JSON from stdin
    | 3. Build notification message
    | 4. Get WeCom access_token via proxy
    | 5. Send DM via proxy (backgrounded)
    v
Public Server (Nginx HTTPS proxy, port 8443)
    |
    | /cgi-bin/*  →  qyapi.weixin.qq.com (reverse proxy)
    | /callback/* →  localhost:8444 (Python callback server)
    v
WeCom API (qyapi.weixin.qq.com)
    |
    v
User's WeCom app (phone / desktop)
```

### 2.2 Configuration

Config file: `~/.claude/cc-notify/config.json` (mode 600)

```json
{
  "corpid": "wwxxxxxxxxxxxxxxxx",
  "corpsecret": "your-app-secret",
  "agentid": "1000002",
  "proxy_url": "https://your-proxy-server.com:8443",
  "userid": "ZhangSan"
}
```

All 5 fields required. Validated by `validate_config.py`.

### 2.3 Event-to-Message Mapping

| Hook Event | Notification Type | Title | Default Reason |
|------------|-------------------|-------|----------------|
| `Stop` | — | `[Claude Code] Task Done` | "Task completed successfully" |
| `Notification` | `permission_prompt` | `[Claude Code] Needs Permission` | "Waiting for permission to proceed" |
| `Notification` | `idle_prompt` | `[Claude Code] Idle` | "Waiting for user input" |
| `Notification` | (other) | `[Claude Code] Notification` | notification_type value |
| (other) | — | `[Claude Code] Event` | event_type value |

Each message includes:
- Line 1: `[Claude Code] <Title>`
- Line 2: `Project: <basename of cwd>`
- Line 3: `Reason: <message field or default>`

### 2.4 Error Handling

**Principle: Never block the CC pipeline.**

| Scenario | Behavior |
|----------|----------|
| Config file missing | stderr warning + `{}` + exit 0 |
| Config invalid (bad JSON, missing fields) | stderr warning + `{}` + exit 0 |
| Proxy unreachable | stderr warning + `{}` + exit 0 |
| Access token request fails | stderr warning + `{}` + exit 0 |
| Message send fails | Backgrounded curl, no impact |
| python3 unavailable | `{}` + exit 0 |

### 2.5 Proxy Server Design

The public server runs two services on Nginx port 8443:

- **`/cgi-bin/*`**: Reverse proxy to `qyapi.weixin.qq.com` — handles API calls (gettoken, message/send)
- **`/callback/*`**: Proxy to local Python server on port 8444 — handles WeCom callback URL verification

The Python callback server (`/opt/wecom-callback/server.py`) does:
- `GET /callback/*`: Decrypts `echostr` parameter and returns plaintext (for WeCom admin URL validation)
- `POST /callback/*`: Returns "success" (acknowledges incoming messages)

### 2.6 Setup Wizard Flow

```
1. Check existing config → offer reconfigure/validate
2. Prompt: corpid (required, non-empty)
3. Prompt: corpsecret (required, silent input)
4. Prompt: agentid (required, numeric)
5. Prompt: proxy_url (required, must start with https://)
6. Prompt: userid (required, ≤64 chars)
7. Write config atomically (temp → chmod 600 → mv)
8. Test: get access_token → send test message
9. Display hook config snippet for settings.json
```

## 3. Implementation

### 3.1 File Structure

```
cc-notify/
  CLAUDE.md                          # Dev instructions
  README.md                          # User-facing documentation
  docs/
    design.md                        # This document
    deployment-guide.md              # Beginner deployment guide
    technical-decisions.md           # Technical decision records
  skills/
    cc-notify/
      SKILL.md                       # Skill definition + setup guide
      scripts/
        notify.sh                    # Hook script
        setup.sh                     # Setup wizard
        validate_config.py           # Config validation
```

### 3.2 Key Implementation Details

**notify.sh:**
- Uses inline `python3 -c` for all JSON parsing (no jq dependency)
- Config loading uses python3 with validation before shell variable assignment
- Curl calls use `-sk` (silent, skip cert verify) for proxy compatibility
- Message send is fully backgrounded via python3 subprocess.Popen

**setup.sh:**
- All prompts read from `/dev/tty` (works even when stdin is piped)
- corpsecret uses `read -rs` (silent input, no echo)
- Config written atomically via temp file + mv
- Each input validated before proceeding
- Chain test: token → message send → confirm

**validate_config.py:**
- Pure python3, no external dependencies
- Validates: file exists, valid JSON, all fields present, format rules
- Exit codes: 0 = valid, 1 = invalid

## 4. Testing

### 4.1 Test Results

| Test | Input | Expected | Result |
|------|-------|----------|--------|
| Config validation (valid) | Full config with all fields | Exit 0, "Config OK" | ✅ Pass |
| Config validation (missing) | No config file | Exit 1, "Config not found" | ✅ Pass |
| Stop event | `{"hook_event_name":"Stop","message":"...","cwd":"..."}` | WeCom DM + exit 0 | ✅ Pass |
| Permission prompt | `{"hook_event_name":"Notification","notification_type":"permission_prompt",...}` | WeCom DM + exit 0 | ✅ Pass |
| Idle prompt (empty msg) | `{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"",...}` | WeCom DM with default reason + exit 0 | ✅ Pass |
| Missing config graceful degradation | Config file removed | stderr warning + `{}` + exit 0 | ✅ Pass |
| Full proxy chain | notify.sh → proxy:8443 → WeCom API → DM | Message delivered | ✅ Pass |

### 4.2 Test Environment

- Remote host: Linux (WSL2)
- Proxy server: Tencent Cloud lightweight server (Ubuntu, Nginx)
- Domain: goods.fatrabbits.shop:8443 (with SSL cert)
- WeCom: Enterprise account, self-built app (agentid: 1000002)
