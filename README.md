# OpenmindProjects — Volunteer Voice Concierge (CALL-E integration)

An AI **voice concierge** for [OpenmindProjects](https://call-e.openmindprojects.org),
a nonprofit that connects volunteers with education projects across Southeast
Asia. Instead of filling in a web form, a volunteer picks up the phone: a CALL-E
voice agent interviews them, checks live availability, and books a real Google
Calendar + Google Meet appointment — no app, no signup.

This repository is a **focused slice** of the full OpenmindProjects platform,
containing only the code that integrates with **CALL-E** and operates phone
calls. The rest of the platform (payments, missions, CRM, reviews) is private.

> **Devpost project:** *Hello Volunteer: Voice Booking Concierge*
> **Live demo:**
> - Volunteer application form: https://call-e.openmindprojects.org/apply/new
> - Book a call form: https://call-e.openmindprojects.org/bookcall
> **Toll-free hotline:** +1 877-757-4423

---

## What it does

Three volunteer flows run through one CALL-E integration:

| Flow | Direction | Trigger | Result |
|------|-----------|---------|--------|
| **Book a callback** | Outbound | Volunteer submits the public "Book a call" form | CALL-E calls them back, interviews them, books a slot |
| **Inbound hotline** | Inbound | Volunteer calls the toll-free number | A dispatcher goal routes to *apply*, *book*, or *read my inbox* |
| **Host voice tasks** | Outbound | A host approves & dispatches an onboarding/feedback task | CALL-E calls the volunteer and reads back the outcome |

Every confirmed appointment lands in **Google Calendar** with a **Google Meet**
link and a confirmation email — the same pipeline the web form uses.

### The "read your inbox" path

The inbound agent is a *static prompt* with no database access, so it can't read
a volunteer's messages mid-call. Instead it captures their identity and triggers
a **two-call read-back**: verify → place an outbound call that reads the unread
messages verbatim. The same logic is also exposed as a reusable **MCP server**
(see `mcp/`).

---

## How it's built

- **CALL-E Developer API v0.7.0** — a thin Ruby HTTP wrapper (CALL-E ships no
  official Ruby SDK), calling `POST /v1/calls` and `GET /v1/calls/{id}` directly.
- **Ruby on Rails 7+** background jobs that start a call, poll to a terminal
  status, then persist the structured result.
- **Google Calendar v3 + Meet** — `conferenceData.createRequest` auto-generates a
  Meet link; events are written to per-type calendars.
- **Model Context Protocol (MCP)** — a dependency-free stdio JSON-RPC 2.0 server
  exposing the inbox/status tools to external agent hosts.

### The core CALL-E call

`app/services/calle_client.rb` wraps the HTTP API and normalizes every response
into a single `Result` value object:

```ruby
result = CalleClient.start_call(
  to_phone: volunteer_phone,          # E.164
  goal: task.voice_goal,              # natural-language script
  result_schema: CalleClient::RECIPIENT_RESULT_SCHEMA
)
# result.run_id => "call_..." — poll until terminal
status = CalleClient.call_status(result.run_id)
```

`start_call` posts a `task` (the natural-language goal), `recipients`, and a
`recipient_result_schema` that tells CALL-E which structured fields to return.

---

## Safety model

CALL-E places real, billed phone calls, so the integration is safe by default:

1. **Dry-run is the default.** `CalleClient#dry_run?` returns true unless
   `CALLE_DRY_RUN=0` is explicitly set — every other path returns a fixture and
   places **no** call:

   ```ruby
   def dry_run?
     ENV["CALLE_DRY_RUN"] != "0"
   end
   ```

2. **Human-in-the-loop.** Host-triggered calls require an explicit *"Approve &
   call"* action; nothing is dispatched automatically.

3. **Multi-factor identity gate** for anything that reveals personal data (the
   read-inbox path — *implemented but blocked upstream on #399*).
   `VolunteerInboxService#verify` requires a known email, a correct 6-digit PIN,
   and (on the hotline) a matching caller phone (ANI):

   ```ruby
   result = VolunteerInboxService.verify(
     email: email, pin: pin, caller_phone: caller_phone
   )
   return unless result.verified?   # nothing is revealed before this
   ```

   Pins are CSPRNG-generated, reversible-encrypted at rest, compared in
   constant time, and protected by a **progressive lockout** (5 failures →
   15 min, exponential backoff). See `app/models/volunteer_contact_pin.rb`.

4. **Overlap-aware slot validation.** A booking is rejected if its start time
   overlaps an existing active booking (a backstop against double-booking).

5. **Unsigned-webhook mitigation.** CALL-E webhook delivery is currently
   unsigned, so the endpoint requires a matching `CALL-E-Event-Id` header and
   optionally verifies an HMAC signature when a secret is configured.

---

## Repository layout

```
app/
  services/
    calle_client.rb            # CALL-E HTTP wrapper (dry-run default)
    calle_registration.rb      # 5-step application → VolunteerApplication
    calle_webhook.rb           # inbound webhook routing (apply/book/read-inbox)
    volunteer_inbox_service.rb # multi-factor identity gate
    google_calendar_service.rb # Calendar + Meet events, per-type calendars
  jobs/
    host_task_voice_call_job.rb  # host-approved outbound voice task
    callback_call_job.rb         # public callback form
    callee_reminder_call_job.rb  # post-booking reminder
    calle_registration_job.rb    # inbound application
    inbound_read_inbox_job.rb    # verified read-back
  models/
    host_task.rb                 # voice_goal assembly + outcome handling
    call_booking.rb              # per-type calendars, slots, overlap guard
    volunteer_contact_pin.rb     # PIN + progressive lockout
    concerns/calle_voice.rb      # shared voice building blocks
  controllers/webhooks/calle_controller.rb
mcp/
  lib/omp_inbox_mcp.rb         # MCP server (Bridge #2)
  server                       # executable
```

> For the exact files to copy into this repo from the full platform, see
> `MANIFEST.md`.

---

## Configuration

| Variable | Purpose | Notes |
|---|---|---|
| `CALLE_API_KEY` | CALL-E project API key | never committed |
| `CALLE_DRY_RUN` | `0` = real calls; anything else = dry-run | default dry-run |
| `CALLE_INBOUND_NUMBER` | toll-free hotline | default `+18777574423` |
| `CALLE_SOURCE` / `CALLE_INTEGRATION` | call metadata | default `openmindprojects` / `mindy_call_booking` |
| `CALLE_MAX_WAIT_SECONDS` / `CALLE_POLL_INTERVAL_SECONDS` | poll loop tuning | default 180 / 10 |
| `GOOGLE_CALENDAR_REFRESH_TOKEN` | Calendar `calendar.events` scope | runtime only |
| `GOOGLE_CAL_ONSITE` / `GOOGLE_CAL_ONLINE` / `GOOGLE_CAL_PARTNERSHIP` | per-type calendar ids | source of truth for slots |
| `VOLUNTEER_PIN_PEPPER` | HMAC pepper for PIN digests | falls back to `secret_key_base` |

Per-organization **bring-your-own-key**: a host organization can store its own
`calle_api_key` and bill its outbound calls to its own CALL-E account, falling
back to the global key when absent.

---

## Running

This slice is extracted from a Rails app; it boots against the platform's
database. Real calls require `CALLE_DRY_RUN=0` and a valid `CALLE_API_KEY`.

```bash
# dry-run (no call placed, no key needed)
CALLE_DRY_RUN=1 bin/rails runner 'puts CalleClient.start_call(to_phone: "+66812345678", goal: "Say hello.").dry_run?'

# real call — explicit opt-in
CALLE_DRY_RUN=0 CALLE_API_KEY=... bin/rails runner 'CalleClient.start_call(to_phone: "+66812345678", goal: "Say hello.")'
```

### MCP server

```bash
./mcp/server   # newline-delimited JSON-RPC 2.0 over stdio
```

See `mcp/README.md` for the tool list, security model, and wiring it into Claude
Code / Codex.

---

## Known limitations

- **Inbound results are blocked** upstream (CALL-E issue #399): inbound calls
  can't deliver a completed result webhook, so the inbound path is code-complete
  but dormant.
- **Inbound goals can't attach external MCP tools** (our feature request): the
  agent can't query the inbox mid-call, hence the two-call read-back.
- **CALL-E has no Ruby SDK** — we call the HTTP API directly.

---

## License / status

Submission for the [CALL-E "Your Code Is Calling" hackathon](https://call-e.devpost.com).
The full OpenmindProjects platform remains private; this repository contains
only the CALL-E-relevant integration.
