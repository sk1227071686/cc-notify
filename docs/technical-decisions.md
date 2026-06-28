# CC Notify — Technical Decision Records

## TDR-001: WeCom App Message API vs Webhook Bot

**Date:** 2026-06-27

**Decision:** Use WeCom App Message API (`/cgi-bin/message/send`) instead of Webhook Bot API.

**Context:** Two WeCom notification mechanisms exist:
- **Webhook Bot**: Sends to a group chat. Simple (just a webhook URL), but only notifies within a group. No direct DM capability.
- **App Message API**: Sends direct DM to a specific user via corpid/secret/agentid. Requires more setup (admin app creation, trusted IP) but targets individuals.

**Rationale:**
- The notification target is a specific user (the CC operator), not a group
- DM notifications are more prominent on the phone (push notification vs group message)
- DM notifications don't require the user to be in a specific group
- The extra setup (app creation, trusted IP) is a one-time cost handled by the setup wizard

**Alternatives considered:**
- Webhook Bot with @mention — mentioned users in group still see it as a group message, less prominent
- Email notifications — requires SMTP setup, less instant, no phone push
- Telegram Bot — not available in China without VPN

---

## TDR-002: Public Server Proxy Architecture

**Date:** 2026-06-27

**Decision:** Use a public server with Nginx HTTPS reverse proxy as a relay between user's machine and WeCom API.

**Context:** WeCom API requires requests to originate from a trusted IP (configured in admin panel). Users on remote SSH hosts typically have dynamic IPs that change frequently.

**Rationale:**
- A public VPS (e.g., Tencent Cloud) provides a static egress IP that can be whitelisted
- Nginx is already commonly installed, minimal additional setup
- HTTPS is required to protect corpsecret in transit
- The proxy is stateless — just forwards requests, no data stored

**Alternatives considered:**
- SSH tunnel from user's machine — complex, fragile, requires the tunnel to stay up
- VPN — overkill for this use case, adds latency and complexity
- Direct API calls without proxy — impossible with dynamic IP + trusted IP requirement

---

## TDR-003: Callback Server for URL Validation

**Date:** 2026-06-27

**Decision:** Deploy a Python HTTP server on the public server to handle WeCom callback URL verification. This server is required to unlock the "Corporate Trusted IP" configuration.

**Context:** WeCom admin panel requires setting up a "Receive Message" callback URL before allowing trusted IP configuration. The verification process involves:
1. WeCom sends GET request with encrypted `echostr` parameter
2. Server must decrypt echostr using AES-CBC with the configured key
3. Server returns the plaintext echostr

**Rationale:**
- Python with `pycryptodome` is the simplest way to implement AES decryption
- The callback server only needs to run for: (a) initial URL verification, (b) receiving future callback events
- It's a lightweight HTTP server (~50 lines of Python), no framework needed
- `pycryptodome` is a well-maintained, widely available package

**Alternatives considered:**
- Implement AES in pure bash — extremely complex, error-prone
- Node.js callback server — requires Node.js runtime on proxy server
- Skip callback setup, find another way to set trusted IP — WeCom doesn't allow this

**Key learning:** The WeCom ecosystem mandates callback URL verification as a prerequisite for ALL security configurations (including trusted IP). This is a non-negotiable requirement that adds significant setup complexity.

---

## TDR-004: Config File vs Environment Variables

**Date:** 2026-06-28

**Decision:** Use `~/.claude/cc-notify/config.json` for configuration instead of environment variables.

**Context:** The hook script needs corpid, corpsecret, agentid, proxy_url, and userid at runtime.

**Rationale:**
- Config file persists across sessions; env vars would need to be set in .bashrc or similar
- Config file is harder to accidentally expose (chmod 600) vs env vars (visible in `ps` output)
- Config file supports validation (validate_config.py)
- Config file allows the setup wizard to write and test atomically
- `~/.claude/` follows Claude Code's convention for user configuration

**Alternatives considered:**
- Environment variables in `~/.bashrc` — visible in process list, harder to validate
- Hardcoded in script — security risk, not distributable
- CLI arguments — CC hooks don't support custom arguments in their protocol

---

## TDR-005: Non-Blocking Message Send with Backgrounded Process

**Date:** 2026-06-28

**Decision:** Send WeCom messages via backgrounded `curl` / `subprocess.Popen`, never block the CC hook pipeline.

**Context:** CC hooks must output `{}` to stdout. Any delay in the hook script delays CC's response loop.

**Rationale:**
- Network calls (gettoken + message/send) can take 1-3 seconds
- CC expects immediate `{}` response from hooks
- If the message send blocks, CC appears to hang
- Backgrounding ensures the hook completes instantly regardless of network conditions
- Fire-and-forget is acceptable — occasional missed notifications are tolerable

**Alternatives considered:**
- Synchronous send with timeout — still adds latency to every CC event
- Queue-based async — overkill, requires a queue daemon
- No notification at all if async fails — current design, acceptable tradeoff

---

## TDR-006: Python3 for JSON Parsing (No jq Dependency)

**Date:** 2026-06-28

**Decision:** Use inline `python3 -c` for all JSON parsing in shell scripts instead of `jq`.

**Context:** The hook script parses CC's JSON input and the WeCom API JSON responses.

**Rationale:**
- python3 is guaranteed available on any system running Claude Code (CC itself requires it)
- No additional package to install (jq may not be available)
- python3's `json` module handles edge cases better than shell string manipulation
- Consistent approach — same tool for all JSON operations

**Alternatives considered:**
- `jq` — not pre-installed on all systems, adds a dependency
- grep/sed/awk — fragile with JSON, escapes and special characters break
- Separate Python script — adds file dependency, harder to deploy

---

## TDR-007: Claude Code Skill Format (Not MCP)

**Date:** 2026-06-28

**Decision:** Implement as a Claude Code Skill (SKILL.md + scripts/) rather than an MCP server.

**Context:** Two extensibility mechanisms exist in Claude Code: Skills and MCP servers.

**Rationale:**
- Skills are simpler to install (`npx skills add`) and require no running process
- The notification function is triggered by CC hooks, not by agent tool calls
- MCP servers require a persistent process and MCP protocol implementation
- Skills integrate directly with the hook system; MCP would need a bridge
- The target audience (individual developers) benefits from the simpler skill model

**Alternatives considered:**
- MCP server — more powerful but adds deployment complexity
- Skill + MCP hybrid — unnecessary complexity for this use case

---

## TDR-008: Single Proxy URL Design

**Date:** 2026-06-28

**Decision:** Use a single proxy URL for all WeCom API calls. The proxy server handles both API forwarding and callback verification via URL path routing.

**Context:** The proxy needs to handle two types of traffic: API calls (/cgi-bin/*) and callback verification (/callback/*).

**Rationale:**
- Single URL simplifies config (one field instead of two)
- Nginx path-based routing is standard and well-understood
- Reduces the number of open ports (one SSL port: 8443)
- Users only need to remember/configure one URL

**Alternatives considered:**
- Separate ports for API proxy and callback — more complex, more firewall rules
- Two URLs in config — more fields to validate and maintain
