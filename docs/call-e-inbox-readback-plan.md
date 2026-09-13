# CALL-E — "Read your Inbox message" Hotline Feature — Dev Plan

> Status: Draft (pre-implementation). Companion to
> `call-e-inbound-dashboard-setup.md`. This feature adds a third dispatcher
> option — **"Read your Inbox message"** — that lets a volunteer call the
> toll-free number and have the AI agent read back their unread messages from
> OpenmindProjects.
#Test volunteer numer: +1 (651) 424-7073
---

## 1. Overview

The existing inbound hotline (`+1 877-757-4423`) currently branches into two
intents: **apply** (`CalleRegistration`) and **book/reschedule**
(`CallBooking.inbound_call_goal`). This plan adds a third:

- **Read your Inbox message** — the volunteer calls, proves who they are, and
  the agent reads their unread host→volunteer messages out loud.

The core architectural fact driving the design: **the CALL-E inbound agent is a
static prompt with no access to our database.** It cannot fetch a specific
volunteer's messages mid-call. So the read happens on a **second, outbound call**
that *we* initiate, with the message text baked into the `goal`.

```
Volunteer ──calls──▶ Inbound agent (dispatcher)
                          │ "read my inbox" → captures email + PIN + intent
                          ▼
                    Webhook POST /webhooks/calle
                          │ read_inbox? intent detected
                          ▼
                    Verify identity (multi-factor)  ← security gate
                          │ pass?
                          ▼
                    Look up unread host→volunteer messages
                          ▼
                    Place OUTBOUND call (CalleClient.start_call)
                    goal = "read these messages to {name}…"
                          ▼
                    Volunteer hears their messages
```

This is the same "callback read-back" pattern that maps directly onto the
hackathon's integration surfaces: API (`POST /v1/calls`), CLI (`calle call
start`), MCP (`run_call`), and the `calle` skill.

---

## 2. Goals / Non-goals

**Goals**
- Add a working, demoable "read my inbox" path to the hotline.
- Enforce multi-factor verification before *any* inbox content is read.
- Reuse existing pieces (`CalleClient.start_call`, `VolunteerContactPin`,
  `Conversation`/`Message`, `CalleWebhook`).

**Non-goals (this iteration)**
- No live mid-call tool/function calling into our DB (unverified CALL-E
  capability — see §7). The read-back bridge is the working substitute.
- No change to the apply/book/reschedule flows beyond the dispatcher prompt.
- No self-hosted voice stack (Mindy/Go ADK) replacement of CALL-E telephony.

---

## 3. User flow (target)

1. Volunteer calls `+1 877-757-4423`.
2. Dispatcher: *"…apply, book/reschedule, or read your inbox message?"*
3. Caller chooses "read my inbox".
4. Agent asks for **email** + **6-digit contact PIN** (identity), and confirms
   intent, then says: *"I'll verify your details and call you right back to
   read your messages."*
5. Call ends → webhook delivers `read_inbox` intent + email + PIN.
6. App verifies identity (see §5). If it fails, the app sends a polite
   "couldn't verify" outbound call or falls back to email.
7. On success, app looks up unread messages and places an outbound call whose
   `goal` contains the messages verbatim.
8. Volunteer hears their messages; optionally the agent asks if they want to
   mark them read.

---

## 4. Identity → message data flow

- `VolunteerContactPin` is keyed by `email_canonical` (trim + lowercase).
- PIN → email → `User.find_by(email:)` (the volunteer) → `Conversation` where
  `volunteer_id = user.id` → unread `Message` where `sender` is host-side and
  `read_at` is nil.

Relevant models:
- `VolunteerContactPin` — PIN auth (already: CSPRNG, encrypted at rest, HMAC +
  constant-time compare).
- `Conversation` — `volunteer`/`host`, `unread_messages_count(current_user)`,
  `host_side_user_ids`, `sender_is_host_side?(sender_id)`.
- `Message` — `sender`, `read_at`, `body`, `message_type` (text/system/
  email_inbound/invoice).

Only host-side messages count as "inbox" content. Inbound synced emails
(`message_type = email_inbound`) may be included or excluded — decision in §6
Task 4.

---

## 5. Security model (multi-factor)

A 6-digit PIN alone is **not** sufficient for reading inbox content (PII,
application data). Verification is layered:

| Factor | Requirement | Notes |
|---|---|---|
| **1. Caller phone (ANI)** | Inbound `caller_phone` must match a phone on file for that volunteer | Highest-value factor; already extracted in `CalleWebhook#caller_phone` |
| **2. Contact PIN** | 6-digit PIN correct for the email | Already exists (`VolunteerContactPin.authenticate`) |
| **3. Rate limit + lockout** | N failures → exponential lockout, per-email and per-phone | **New** — currently absent |
| **4. Knowledge factor** | If ANI doesn't match: DOB / last booking `OMP-xxxxx` / last-4 phone | **New** — fallback when caller changed numbers |

Policy:
- **Read inbox**: ANI match **+** PIN **+** rate-limit (knowledge factor if ANI
  mismatches). *Zero* content is revealed until all required factors pass.
- **Book/reschedule**: PIN (soft-fail, unchanged) + rate-limit.
- **Application status**: PIN + rate-limit.

Threat model notes:
- Brute-force via calls is naturally slow, but any fast lookup path (the future
  MCP/read endpoint) must be rate-limited server-side regardless of channel.
- PIN is the *only* secret; email is the (semi-public) lookup key. Never rely on
  PIN alone for sensitive data.
- Webhook is unsigned (`CALL-E-Event-Id` only) — treat `contact_pin`/`email` as
  untrusted candidates to verify, never as truth.
- Do not echo the PIN in transcripts/logs/`structured_result` beyond the
  verification step; it is already encrypted at rest.

---

## 6. Components & tasks

### New/changed files

| File | Change |
|---|---|
| `db/migrate/*_add_rate_limit_to_volunteer_contact_pins.rb` | Add `failed_attempts` (int, default 0) + `locked_until` (datetime) |
| `app/models/volunteer_contact_pin.rb` | Rate-limit/lockout in `authenticate`/`find_authenticated`; `reset_lock!`; per-email + per-phone tracking |
| `app/services/volunteer_inbox_service.rb` | **New** — `verify!` (multi-factor) + `unread_messages_for(email)` (returns text the agent can read) |
| `app/services/calle_webhook.rb` | Add `read_inbox?` detection + `read_inbox_attributes` |
| `app/controllers/webhooks/calle_controller.rb` | Route `read_inbox?` → `InboundReadInboxJob` |
| `app/jobs/inbound_read_inbox_job.rb` | **New** — verify → lookup → `CalleClient.start_call` read-back |
| `app/services/calle_client.rb` | Add `read_inbox` field to the union result schema (+ a `read_inbox_goal` prompt) |
| `app/docs/call-e-inbound-dashboard-setup.md` | Update dispatcher goal + result schema + verify steps |

### Task list

1. **Migration + rate limiting** — add `failed_attempts`/`locked_until`; enforce
   in `VolunteerContactPin.authenticate` (e.g. 5 failures → 15 min lock, then
   exponential). Acceptance: wrong PIN 5× locks; correct PIN resets counter.
2. **`VolunteerInboxService`** — `verify(email:, pin:, caller_phone:)` returning
   a `verified`/`unverified` + reason; `unread_messages_for(email)` returning
   host-side unread messages as a plain-text list. Acceptance: unit tests for
   pass/fail/lockout and empty-inbox.
3. **Webhook routing** — detect `read_inbox` in `structured_result` and route to
   `InboundReadInboxJob` (before/alongside booking/registration checks).
4. **`InboundReadInboxJob`** — idempotent on `run_id`; verify → on success place
   outbound read-back call (dry-run by default via `CalleClient.dry_run?`); on
   failure, no content is read. Decision: include/exclude `email_inbound`.
5. **Dispatcher prompt** — add the third option + the "ask email + PIN, say
   we'll call back" script; update the union result schema with `read_inbox`.
6. **Docs** — update `call-e-inbound-dashboard-setup.md` (Step 2 dispatcher,
   Step 3 schema, Step 5 verify).

---

## 7. Bridge #2 — Custom MCP server (parallel workstream)

**What** — build our own MCP server exposing domain tools, and pitch CALL-E to
let inbound goals attach external MCP tools. This is the "help shape what it
becomes" contribution: a reusable integration plus product feedback.

**Why** — Bridge #1 works today but is two calls (call in → call back). A live
tool call would let the inbound agent fetch data mid-call. CALL-E doesn't yet
document inbound tool-calling, so this workstream is exploratory and doubles as
a feature request.

**Tools to expose** (each returns plain text the agent can read aloud):
- `get_unread_messages(email, pin)` → text
- `get_application_status(email, pin)` → text
- `book_appointment(...)` → structured (reuse `CallBooking`)
- *(stretch)* `mark_messages_read(email, pin)`

**Security** — every tool reuses the §5 multi-factor gate (PIN required; ANI
when available) and is rate-limited server-side. No tool returns data for an
unverified identity.

**Components / files**

| File | Change |
|---|---|
| `mcp/` (new) | Lightweight MCP server (stdio or streamable HTTP) wrapping `VolunteerInboxService` + `VolunteerContactPin` |
| `app/services/volunteer_inbox_service.rb` | Shared with Bridge #1 (single source of truth) |
| `mcp/README.md` | Tool manifest, auth model, dry-run/setup docs |
| `app/docs/call-e-inbound-dashboard-setup.md` | Add feature-request text (inbound + external MCP tools) |

**Tasks**

1. Scaffold the MCP server (stdio) with a working `get_unread_messages` tool.
2. Wire the §5 auth + rate-limit gate into every tool.
3. Run it in an agent host (Claude Code / Codex) and demo one tool call
   end-to-end against `VolunteerInboxService`.
4. Draft the CALL-E feature request ("inbound goals should support external MCP
   tools") with our server as the reference implementation.

**Dependency** — unverified whether CALL-E inbound goals can attach MCP tools.
Bridge #1 is unaffected either way.

---

## 8. Dependencies / open questions

- **Caller ANI availability** — confirm CALL-E delivers the caller's phone
  number on inbound events (the `from`/`caller`/`caller_number` fields
  `CalleWebhook` already reads). This is assumed but unverified end-to-end.
- **Inbound tool/function calling** — the *ideal* fix (live DB lookup) is a
  CALL-E feature request; the read-back bridge is the interim path.
- **Which phone number(s) count as "on file"** for ANI match — `User`,
  `VolunteerApplication`, and/or `CallBooking`.
- **Mark-as-read** — whether the outbound agent should mark messages read (a
  separate, lower-priority follow-up).

---

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| PIN brute-forced via fast path | Server-side rate-limit/lockout; multi-factor for inbox |
| ANI not delivered by CALL-E | Fall back to knowledge factor; document the limitation |
| Read-back call leaks PII to wrong caller | Full verification *before* any content is read |
| Outbound call costs | Dry-run default (`CALLE_DRY_RUN != "0"`); live opt-in |
| Unsigned webhook forgery | Treat payload as untrusted; idempotency on `run_id` |
