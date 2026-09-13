# CALL-E Vendor Support Report

> **Status:** Draft — to be submitted to CALL-E support.
> **Last updated:** 2026-09-13
> **Prepared by:** OpenmindProjects
> **Account:** `gaweechat@gmail.com`
> **API base:** `https://api.heycall-e.com` (Developer API v0.7.0)

This document consolidates every issue we have observed with the CALL-E platform
that is worth reporting to the vendor. Each issue carries a stable ID (`CSE-*`),
a severity, reproduction evidence, and the outcome we need. One submission can
cite all of these.

***

## How to submit

- **Email:** `support@heycall-e.com`
- **Discord:** <https://discord.gg/6AbXUzUV8w>
- **GitHub:** <https://github.com/CALLE-AI> (see `awesome-phone-call-agents`)
- **Existing open issue:** #399 — "Support result webhooks for Dashboard inbound Goals"

Paste the relevant sections below (or the whole file) and reference the `CSE-*`
IDs in the subject line, e.g.:

> Subject: OpenmindProjects CALL-E issues — inbound webhooks (#399), audio loop, and list API gaps

### Attribution

The `CSE-*` IDs are our internal tracking numbers; the vendor will not recognize
them. Attribution to OpenmindProjects follows the account and the support thread,
not our local IDs, so open the report with an explicit statement of who we are
and which issue is ours. Send from (or clearly identify) the organization, not
just a personal Gmail. This is a report for the record only — no response,
ticket, or action is required.

Paste this opening block before the sections below:

```text
Hi,

We are OpenmindProjects (https://call-e.openmindprojects.org), the team behind
the CALL-E account registered as gaweechat@gmail.com. This is a consolidated
report and a follow-up to GitHub issue #399 that our team member
Gaweechat Joompaula filed on 9 Sep.

This report is for your records only — no response or action is required.
The issues below are labeled CSE-1 through CSE-12 for our internal tracking;
#399 remains our primary blocker.
```

***

## Priority overview

| ID     | Issue                                                                         | Severity | Blocks                                        | Status                |
| ------ | ----------------------------------------------------------------------------- | -------- | --------------------------------------------- | --------------------- |
| CSE-1  | No inbound result webhook / discovery API                                     | Critical | Entire inbound phone-in path                  | Blocked (vendor #399) |
| CSE-2  | No list/discovery endpoint for calls or goals                                 | High     | Auditing, reconciliation, "find a call by id" | Open                  |
| CSE-3  | Short one-word answers are not detected (audio loop)                          | High     | Outbound booking calls                        | Open                  |
| CSE-4  | Choppy/fragmented TTS + barge-in cuts off greetings                           | High     | Call quality                                  | Open                  |
| CSE-5  | No voice / pitch / tone / speech-rate parameters                              | Medium   | Call quality                                  | Open                  |
| CSE-6  | Thailand `+66` region rejected                                                | Medium   | Thai volunteers                               | Open                  |
| CSE-7  | Retry/not-available signal only in free text                                  | Low      | Auto-retry timing                             | Open                  |
| CSE-8  | Inbound webhook is unsigned                                                   | Low      | Security posture                              | Open                  |
| CSE-9  | Agent audio degraded (whispering, non-English) + transcript omits agent turns | High     | Call quality / auditing                       | Open                  |
| CSE-10 | Voice-media encryption + call-recording retention unconfirmed                 | Medium   | Security / DPA posture                        | Open                  |
| CSE-11 | No dynamic data / tool-calling for real-time slot availability                | Medium   | Overbooking / double-booking                  | Open                  |
| CSE-12 | Inbound goals can't attach external MCP tools                                  | Medium   | Single-call inbox read-back                   | Open                  |

***

## CSE-1 — No inbound result webhook / discovery API

**Severity:** Critical · **Status:** Blocked (vendor issue #399)

**Description**

The entire inbound flow (volunteer calls our toll-free `+1 877-757-4423` and the
agent fills the application / books an appointment) is wired in our code but has
**no event source**. CALL-E does not deliver completed-call results for inbound
(Dashboard) goals, and there is no inbound Developer API to discover completed
calls or read their results.

**Evidence**

Confirmed by CALL-E on 2026-09-09 (issue #399, `priority:p3`, `needs-triage`).
A vendor-side read-only probe found no usable inbound result path:

| Endpoint                       | Result                                                             |
| ------------------------------ | ------------------------------------------------------------------ |
| `GET /v1/goals?limit=100`      | `200` but empty (3 inbound goals exist in Dashboard, none exposed) |
| `GET /v1/goals/{goal_id}`      | `409 goal_not_ready` (all 3)                                       |
| `GET /v1/goals/{goal_id}/runs` | `405 Method Not Allowed`                                           |
| `GET /v1/calls`                | `405 Method Not Allowed` (no list endpoint)                        |

**Impact**

Inbound phone-in booking/registration is fully blocked end-to-end. We cannot
receive results from calls placed *to* our toll-free number. This also blocks
our "read your inbox" hotline feature, which depends on the same inbound result
webhook.

**Desired outcome**

Enable inbound delivery to `https://relays-omp-calle-app.ra1zsf.easypanel.host/webhooks/calle`
using the documented terminal event envelope `{ id, type, created_at, data: { …CallTask } }`
with the `CALL-E-Event-Id` header and at-least-once delivery, and send a test event.

***

## CSE-2 — No list/discovery endpoint for calls or goals

**Severity:** High · **Status:** Open

**Description**

There is no way to enumerate calls, goals, or runs programmatically. This makes
it impossible to audit our own call history or reconcile orphaned records, and it
prevents reverse-looking-up a call by its dashboard "call id".

**Evidence**

- `GET /v1/calls` → `405 Method Not Allowed`.
- `GET /v1/calls/{id}` only works for the `call_…` task id, not the dashboard
  "call id" (32-hex). Our lookup of `74230e0d8c804bd3bd74aca0620935d5` returned
  `404 not_found` even though that id appears in our dashboard.

**Impact**

We cannot build a reconciliation job or a "look up this call" tool; debugging a
bad call requires manual dashboard copy/paste.

**Desired outcome**

A read-only list endpoint (`GET /v1/calls?limit=&cursor=`) and a way to fetch a
call by either the task id *or* the dashboard call id.

***

## CSE-3 — Short one-word answers are not detected (audio "hello" loop)

**Severity:** High · **Status:** Open

**Description**

When a callee replies with a short one-word answer ("Yes", "Hello?"), the agent
does not register the speech and re-asks the same confirmation. This degenerates
into a "can you hear me? / are you still with me?" loop and the agent stalls
without ever collecting the appointment.

**Evidence** (call id `b9eeadb97ea44201a1368f4fb0f5c70b`)

```text
[ASSISTANT]: Hello, can you hear me?
[USER]: Hello? Yes.
[ASSISTANT]: Hello! Great, I'm OpenmindProjects calling to schedule your 30-minute appointment in Asia/Bangkok time.
[USER]: Yes.
[ASSISTANT]: Perfect
[ASSISTANT]: Hi
[ASSISTANT]: Can you hear me?
[USER]: Yes. I can hear you.
[ASSISTANT]: Great.
[ASSISTANT]: Are / You / Still / With / Me / Hello / I / 'm / Checking / In
[ASSISTANT]: <dialog-end>
```

The user confirmed "yes I can hear you" twice, yet the agent re-confirmed again
and then stalled. No appointment type, date/time, or email was captured.

**Impact**

This is our primary outbound booking flow; when it loops, the appointment is
never scheduled and the call is wasted.

**Desired outcome**

Investigate voice-activity detection / barge-in sensitivity to short one-word
utterances, so a clear "yes" is treated as a valid turn and the agent advances.

***

## CSE-4 — Choppy/fragmented TTS + barge-in cuts off greetings

**Severity:** High · **Status:** Open

**Description**

Two related symptoms in the same call:

1. The assistant's speech is emitted one word at a time
   (`Are / You / Still / With / Me / Hello / I / 'm / Checking / In`), suggesting
   the TTS/streaming is chunking each word into its own turn or the model is
   stalling between tokens.
2. The opening greeting was cut off mid-word (`Hi Dev7 Development, thi … [interrupted]`),
   suggesting barge-in/echo is interrupting the agent's own speech.

**Evidence** — same transcript as CSE-3.

**Impact**

Makes the agent sound broken/robotic and can abort the greeting before the caller
hears who is calling.

**Desired outcome**

Stable, continuous TTS for a single turn, and barge-in that does not interrupt
the agent's own opening line.

***

## CSE-5 — No voice / pitch / tone / speech-rate parameters

**Severity:** Medium · **Status:** Open

**Description**

The Developer API (v0.7.0) exposes **no** voice, speech-rate, pitch, or tone
parameters. `POST /v1/calls` accepts only `task`, `recipients[].locale/region`,
`result_schema` / `recipient_result_schema`, `metadata`, and `webhook_url`.

**Impact**

The entire voice profile (warmth, pacing, energy) must be expressed as
natural-language instructions in the `task` string, which is unreliable across
calls and models. We cannot guarantee a consistent brand voice.

**Desired outcome**

Expose voice/tone/speech-rate options on the API (or confirm a supported way to
pin a voice model) so voice quality is deterministic rather than prompt-luck.

***

## CSE-6 — Thailand `+66` region rejected

**Severity:** Medium · **Status:** Open

**Description**

Live calls to Thai `+66` numbers are rejected by the CALL-E API. Only US numbers
have been verified live.

**Evidence**

Project memory / live-test notes: Thailand `+66` is "currently rejected by the
CALL-E API — a provider-side limitation."

**Impact**

OpenmindProjects is a Thailand-based nonprofit, and Thailand (`+66`) is one of
our volunteer audiences, but not the primary one. Most volunteers are overseas
(primarily the US and EU), so only the Thai subset is blocked; our core audience
can still be reached.

**Desired outcome**

Enable `+66` (and ideally the broader SEA region) for outbound calls, or provide
a clear timeline/supported-region list.

***

## CSE-7 — Retry / not-available signal only in free-text summary

**Severity:** Low · **Status:** Open

**Description**

When a call reaches voicemail or the caller is unavailable, CALL-E sometimes
suggests a retry ("I suggest retrying in about 45 minutes") but that hint exists
only in the free-text `summary`, not in the structured result.

**Evidence**

Live call `run_id=call_Rj_DV-RSIzcMQMWEodJxRg` hit an automated voicemail; the
summary said *"I suggest retrying in about 45 minutes."* No `retry_after_minutes`
or `not_available` field was present in `structured_result`.

**Impact**

We had to hardcode a fixed retry delay; we cannot use the agent's own timing hint.

**Desired outcome**

Add structured fields (e.g. `retry_after_minutes`, `not_available`, `voicemail`)
to the result schema so downstream automation can act on the suggested timing.

***

## CSE-8 — Inbound webhook is unsigned

**Severity:** Low · **Status:** Open

**Description**

CALL-E's inbound webhook delivery is unsigned — there is no webhook secret,
`CALL-E-Timestamp`, or `CALL-E-Signature` header. We currently validate only by
requiring the `CALL-E-Event-Id` header to match the body event `id`.

**Impact**

Weaker integrity guarantees for a server-to-server endpoint that ingests PII
(name, email, phone).

**Desired outcome**

Add optional HMAC-SHA256 signing (`X-Calle-Signature` + timestamp) so we can
cryptographically verify event authenticity.

***

## CSE-9 — Agent audio degraded (whispering, non-English) + transcript omits agent turns

**Severity:** High · **Status:** Open

**Description**

In one call the agent's audio was partially unintelligible: it was audibly
whispering at times and producing words/phrases that did not sound like English.
Separately, the text transcript for the same call does not capture how the agent
responded at those moments — the assistant's turns are missing from the
transcript, so we cannot tell from the dashboard what the caller actually heard.

Two related symptoms:

1. **Audio quality** — the agent whispers at times and speaks words that sound
   like non-English/garbled output, suggesting a TTS/voice-model fault or a
   locale/language switch mid-call.
2. **Transcript completeness** — the returned text transcript skips the agent's
   responses, so there is no record of what the agent said even when audio is
   present.

**Evidence** (call id `2f700a2a9e22427e9745ed54f6f0edc8`)

- Audio recording: agent audibly whispering during some turns and uttering words
  that do not sound like English.
- Text transcript: agent response turns are absent — the transcript shows the
  caller's side but not how the agent responded.

**Impact**

We cannot audit the call: the agent may have asked for the wrong information or
confirmed the wrong appointment, and the missing transcript plus unintelligible
audio leaves no recoverable record. For a booking call this risks scheduling the
wrong time or losing the caller's trust.

**Desired outcome**

1. Investigate why the TTS/voice output degraded into whispering and
   non-English-sounding speech (and whether a locale/language switch occurred).
2. Ensure the transcript faithfully records every assistant turn, including when
   audio quality degrades, so calls remain auditable.

***

## CSE-10 — Voice-media encryption + call-recording retention unconfirmed

**Severity:** Medium · **Status:** Open

**Description**

We cannot confirm from the Developer API whether the live voice call between the
volunteer and the agent is encrypted in transit, nor whether CALL-E retains the
raw audio after the call. Our integration only exchanges text (transcript,
summary, structured result) over TLS; the audio path is entirely on CALL-E's
telephony provider side and is not visible to us.

Two open questions:

1. **Media encryption** — is the volunteer↔agent voice stream encrypted in
   transit (SRTP / DTLS-SRTP), or is the PSTN leg carried in the clear?
2. **Recording retention** — does CALL-E store the raw call audio, and if so for
   how long, and how is it protected at rest?

**Impact**

Without confirmation we cannot complete our security / DPA posture for voice
calls that collect PII (name, email, phone), and it leaves a gap in our GDPR
notes for the phone-in application flow.

**Desired outcome**

Document (or expose via the API) the media-transport encryption and the
recording-retention policy, so we can record the actual in-transit and at-rest
protection of the voice leg.

***

## CSE-11 — No dynamic data / tool-calling for real-time slot availability

**Severity:** Medium · **Status:** Open

**Description**

The Developer API accepts only a static `task` string (plus `recipients`,
`result_schema` / `recipient_result_schema`, and `metadata`). There is no
tool/function calling, dynamic context, or calendar integration, so the agent
cannot read our live availability while a call is in progress. Availability must
be baked into the `task` at dispatch time as a snapshot, and any booking made
after that snapshot — including a slot taken by another call while this one is
still in flight — is invisible to the agent.

**Impact**

The agent can offer a slot that has already been taken, causing overbooking or
double-booking. We mitigate on our side in two ways:

1. We snapshot the currently free slots into the `task` at dispatch time. Those
   slots are now sourced per-type from dedicated Google Calendars (one per
   appointment type), which hosts maintain as the single source of truth — so the
   snapshot reflects real availability rather than hardcoded windows.
2. We enforce an overlap-aware uniqueness validation on our side that rejects a
   returned slot within 30 minutes of an existing booking.

This reduces but does not eliminate the risk, because the snapshot goes stale the
moment another call books a slot.

**Desired outcome**

Provide a way to pass dynamic context to the agent — for example a tool/function
call, a webhook the agent can invoke, or a calendar free/busy integration — so
the agent can offer only slots that are actually free at the moment it offers
them.

***

## CSE-12 — Inbound goals can't attach external MCP tools (forces two-call read-back)

**Severity:** Medium · **Status:** Open (feature request drafted)

**Description**

Inbound (Dashboard) goals are static prompts with no access to our database, and
there is no way to attach external MCP tools to an inbound goal. Any mid-call
data lookup — for example reading a specific volunteer's unread messages — has
to be done as a **two-call "read-back" bridge**: the inbound call verifies the
caller and ends, then we place a second outbound call whose `goal` contains the
looked-up text. This is the inbound counterpart of CSE-11 (which covers outbound
tool-calling for slot availability).

**Evidence**

We built a reference MCP server (`mcp/`, stdio JSON-RPC 2.0) exposing
`get_unread_messages(email, pin)` and `get_application_status(email, pin)`, both
PIN-gated through the same multi-factor `VolunteerInboxService` the hotline
uses. The feature request (asking CALL-E to let inbound goals attach external
MCP tools) is drafted in `app/docs/call-e-inbound-dashboard-setup.md`.

**Impact**

The "read my inbox" hotline feature must run as two separate calls (call in →
verify → call back), which is slower, more error-prone, and costs an extra
outbound call per request. It also compounds with CSE-1: even this two-call
bridge is blocked today because the inbound result webhook (#399) is not
provisioned.

**Desired outcome**

Allow inbound goals to attach one or more external MCP servers (stdio or
streamable HTTP), stream tool results back as plain text the agent reads aloud
mid-call, and document the auth model for tool calls originating from an inbound
call (caller ANI, PIN, etc.).

***

## Appendix A — Evidence call IDs

| ID                                 | Kind                   | Observed                                                                   |
| ---------------------------------- | ---------------------- | -------------------------------------------------------------------------- |
| `b9eeadb97ea44201a1368f4fb0f5c70b` | dashboard call id      | audio "hello" loop + fragmented TTS (CSE-3, CSE-4)                         |
| `74230e0d8c804bd3bd74aca0620935d5` | dashboard call id      | `GET /v1/calls/{id}` returned `404` (CSE-2)                                |
| `call_Rj_DV-RSIzcMQMWEodJxRg`      | API task id (`run_id`) | voicemail, retry hint in free text only (CSE-7)                            |
| `2f700a2a9e22427e9745ed54f6f0edc8` | dashboard call id      | whispering / non-English audio + missing agent turns in transcript (CSE-9) |

## Appendix B — Reference documents (internal)

- `call-e-inbound-dashboard-setup.md` — inbound webhook blocker + vendor probe (CSE-1, CSE-2).
- `call-e-voice-profile.md` — no voice parameters (CSE-5).
- `call-e-registration-analysis.md` — Thailand `+66` blocked (CSE-6).
- `call-e-volunteer-pipeline-issue-tracker.md` — voicemail/retry evidence (CSE-7).

