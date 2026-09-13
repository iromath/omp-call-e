# OpenmindProjects Inbox MCP server (Bridge #2)

A minimal, dependency-free [Model Context Protocol (MCP)](https://modelcontextprotocol.io)
server over stdio that exposes a couple of read-only OpenmindProjects tools to an
external agent host (Claude Code, Codex, Cursor, …).

This is the reusable integration behind **Bridge #2** of
[`docs/call-e-inbox-readback-plan.md`](../docs/call-e-inbox-readback-plan.md): the
phone hotline already uses a two-call read-back (call in → verify → call back),
and this MCP surface is the same logic exposed to a host agent instead of a
phone call.

## Tools

| Tool | Arguments | Returns | Auth |
|---|---|---|---|
| `get_unread_messages` | `email`, `pin` | Unread host→volunteer inbox messages as plain text (empty → `"No unread messages."`) | PIN + rate-limit |
| `get_application_status` | `email`, `pin` | Latest application name / status / type / submitted date as plain text | PIN + rate-limit |

Both tools return plain text (MCP `text` content) so a host agent can read it
back or summarize it.

## Security model

Every tool funnels through [`VolunteerInboxService`](../app/services/volunteer_inbox_service.rb),
the same gate the hotline uses:

1. `email` must resolve to an existing `VolunteerContactPin`.
2. The record must not be locked out.
3. `pin` must match (constant-time HMAC compare).
4. Wrong PINs feed the progressive lockout (`MAX_FAILED_ATTEMPTS = 5`,
   `BASE_LOCKOUT = 15 min`, exponential backoff).

**There is no caller-phone (ANI) factor here** — an MCP host has no telephony
ANI. The hotline keeps ANI enforcement on
(`VolunteerInboxService::REQUIRE_ANI_FOR_INBOX = true`); the MCP tools call
`verify(..., require_ani: false)` and rely on PIN + rate limiting instead. If
you need stricter access for an MCP channel, add an API token at the transport
layer (not in this reference server).

## Running it

```bash
cd app

# Point at your database (local dev shown; omit to use the online DB).
DATABASE_URL="postgres://newomp:devpassword@localhost:5434/newomp_development" \
DB_HOST=localhost DB_PORT=5434 DB_NAME=newomp_development \
DB_USER=newomp DB_PASSWORD=devpassword \
./mcp/server
```

It boots the full Rails app (needed for `ActiveRecord::Encryption` on the PIN
column), then speaks newline-delimited JSON-RPC 2.0 over stdio. **stdout carries
only the JSON-RPC stream**; Rails/ActiveRecord logging is redirected to stderr.

### Wire it into an agent host

Claude Desktop / Claude Code config (`claude_desktop_config.json` / `.mcp.json`):

```json
{
  "mcpServers": {
    "omp-inbox": {
      "command": "/home/tradex/Documents/dev-plan/Call-E/app/mcp/server",
      "env": {
        "DATABASE_URL": "postgres://newomp:devpassword@localhost:5434/newomp_development",
        "DB_HOST": "localhost",
        "DB_PORT": "5434",
        "DB_NAME": "newomp_development",
        "DB_USER": "newomp",
        "DB_PASSWORD": "devpassword"
      }
    }
  }
}
```

## Verifying (smoke test)

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_unread_messages","arguments":{"email":"you@example.com","pin":"123456"}}}' \
  | ./mcp/server
```

## Planned follow-ups

- `book_appointment(...)` — reuse `CallBooking` to create a booking from an agent.
- `mark_messages_read(email, pin)` — mark returned messages read.
- A transport-level auth token (in addition to, not instead of, the PIN gate).

## Feature request to CALL-E

The real goal is for CALL-E **inbound goals to support external MCP tools**, so
the inbound agent can fetch a volunteer's messages *mid-call* instead of the
two-call read-back. See the "Bridge #2 — feature request" section of
[`docs/call-e-inbound-dashboard-setup.md`](../docs/call-e-inbound-dashboard-setup.md).
