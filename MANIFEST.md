# MANIFEST.md

This repository is a **deliberately curated slice** of the private
OpenmindProjects platform, containing only the code that integrates with
**CALL-E** and operates phone calls. This manifest records exactly which files
were extracted, and which parts of the full platform were intentionally left out.

`app/` paths below mirror their location in the full platform tree (the slice
preserves the original directory structure).

---

## Included files

### Root

| File | Purpose |
|------|---------|
| `README.md` | Project overview, architecture, safety model, configuration |

### `app/controllers/webhooks/`

| File | Purpose |
|------|---------|
| `calle_controller.rb` | Inbound CALL-E webhook endpoint (apply / book / read-inbox routing) |

### `app/services/`

| File | Purpose |
|------|---------|
| `calle_client.rb` | CALL-E Developer API HTTP wrapper (dry-run by default) |
| `calle_registration.rb` | 5-step voice application → `VolunteerApplication` |
| `calle_webhook.rb` | Inbound webhook routing + unsigned-webhook mitigation |
| `volunteer_inbox_service.rb` | Multi-factor identity gate (email + PIN + caller ANI) |
| `google_calendar_service.rb` | Google Calendar v3 + Meet events, per-type calendars |

### `app/jobs/`

| File | Purpose |
|------|---------|
| `host_task_voice_call_job.rb` | Host-approved outbound voice task |
| `callback_call_job.rb` | Public "Book a call" callback form |
| `callee_reminder_call_job.rb` | Post-booking reminder call |
| `calle_registration_job.rb` | Inbound application job |
| `inbound_read_inbox_job.rb` | Verified read-back of unread inbox messages |
| `inbound_call_booking_job.rb` | Turns a completed inbound call into a real booking |

### `app/models/`

| File | Purpose |
|------|---------|
| `host_task.rb` | `voice_goal` assembly + outcome handling |
| `call_booking.rb` | Per-type calendars, slot overlap guard, run-id idempotency |
| `volunteer_contact_pin.rb` | PIN generation, constant-time compare, progressive lockout |
| `concerns/calle_voice.rb` | Shared voice building blocks |

### `mcp/`

| File | Purpose |
|------|---------|
| `lib/omp_inbox_mcp.rb` | Dependency-free MCP (JSON-RPC 2.0) server implementation |
| `server` | Executable entrypoint — boots Rails, reuses the PIN/rate-limit gate |
| `README.md` | MCP tool list, security model, host wiring |

### `docs/`

| File | Purpose |
|------|---------|
| `call-e-inbox-readback-plan.md` | Dev plan for the "Read your Inbox" hotline feature |
| `call-e-vendor-support-report.md` | Consolidated CALL-E vendor issues (`CSE-*`) |

### `skills/`

| File | Purpose |
|------|---------|
| `volunteer-voice-booking/SKILL.md` | Portable Agent Skill: callback booking flow |
| `volunteer-voice-booking/references/safety.md` | Safety rules (disclosure, masking, human gate) |
| `volunteer-voice-booking/references/examples.md` | Safe/unsafe request JSON + dry-run output shape |
| `volunteer-voice-booking/scripts/preview-volunteer-booking.mjs` | No-call dry-run preview |
| `volunteer-voice-booking/assets/sample-volunteer-request.json` | Sample input for the dry-run preview |

---

## Intentionally excluded

These parts of the full platform are **not** in this repo, by design:

- **Database layer** — `db/schema.rb`, `db/sql/*`, migrations. The slice boots
  against the platform database and does not expose private data models.
- **Out-of-scope domains** — payments, missions, CRM, and reviews
  controllers/models/services.
- **Web UI** — `app/views/*` and the public application/callback forms' markup.
- **Secrets** — `.env`, credentials, service-account keys, and any API keys
  (`CALLE_API_KEY`, `GOOGLE_CALENDAR_REFRESH_TOKEN`, etc.) are runtime-only and
  never committed.
- **The remainder of the platform** — everything not directly involved in the
  CALL-E voice integration.
