# Thin wrapper around the CALL-E Developer API.
#
# Mindy is Ruby, but CALL-E's official SDKs target Python/TypeScript, so we call
# the HTTP API directly with a project API key (CALLE_API_KEY). The key is kept
# in .env and never committed.
#
# Safety:
#   * Dry-run is the DEFAULT — real calls are only placed when
#     CALLE_DRY_RUN=0 is explicitly set. Everything else returns a fixture.
#   * API responses are treated as untrusted and parsed defensively.
#   * This service blocks on HTTP, so it must only be called from a background
#     job, never from a Falcon request fiber.
require "net/http"
require "json"
require "uri"

class CalleClient
  class Error < StandardError; end

  # Value object holding the normalized result of a CALL-E call task.
  Result = Struct.new(
    :run_id, :status, :summary, :transcript, :callee_number, :duration_seconds, :activity, :structured_result, :dry_run,
    keyword_init: true
  ) do
    TERMINAL = %w[COMPLETED FAILED NO_ANSWER DECLINED CANCELED CANCELLED VOICEMAIL BUSY EXPIRED].freeze

    def terminal?
      TERMINAL.include?(status.to_s.upcase)
    end

    # True when this result came from the dry-run fixture (no real call placed).
    def dry_run?
      dry_run == true
    end
  end

  DEFAULT_BASE_URL = "https://api.heycall-e.com".freeze
  DEFAULT_MAX_WAIT_SECONDS = 180
  DEFAULT_POLL_INTERVAL_SECONDS = 10
  DEFAULT_LOCALE = "en-US".freeze

  # Toll-free inbound hotline volunteers call to apply (or book) by phone. The
  # AI agent answers, guides the caller through the application, and fills out
  # the form. E.164 form is for tel: links; display form is for UI copy.
  INBOUND_NUMBER = ENV.fetch("CALLE_INBOUND_NUMBER", "+18777574423").freeze
  INBOUND_NUMBER_DISPLAY = "+1 877-757-4423".freeze

  # E.164 country code -> CALL-E routing region. English (DEFAULT_LOCALE) is the
  # product's conversation language for every destination, so only the region
  # hint is provided here.
  COUNTRY_ROUTING = {
    "66" => { region: "TH" }
  }.freeze

  # Structured result CALL-E should populate per recipient. Fields are optional
  # and mirror the natural-language goal; the reschedule flow consumes the
  # booking-number / preferred-time fields.
  RECIPIENT_RESULT_SCHEMA = {
    "type" => "object",
    "properties" => {
      "request_summary" => { "type" => "string" },
      "email" => { "type" => "string" },
      "program_interest" => { "type" => "string" },
      "availability" => { "type" => "string" },
      "partnership_type" => { "type" => "string" },
      "returning_volunteer" => { "type" => "boolean" },
      "previous_booking_number" => { "type" => "string" },
      "reschedule_requested" => { "type" => "boolean" },
      "preferred_date_time" => { "type" => "string" },
      "preferred_callback_at" => { "type" => "string" },
      "purpose" => { "type" => "string" },
      "received_email" => { "type" => "string" },
      "questions" => { "type" => "string" }
    }
  }.freeze

  # Structured result for the INBOUND line (volunteers call our toll-free
  # number). The agent captures the same fields the online form does, so the
  # inbound webhook can create a CallBooking and reuse the whole pipeline.
  # `read_inbox` is the dispatcher's third intent — a flag that routes the
  # completed call to the read-back bridge rather than booking/registration.
  INBOUND_RESULT_SCHEMA = {
    "type" => "object",
    "properties" => {
      "read_inbox" => { "type" => "boolean" },
      "name" => { "type" => "string" },
      "email" => { "type" => "string" },
      "purpose" => { "type" => "string" },
      "preferred_date_time" => { "type" => "string" },
      "contact_pin" => { "type" => "string" },
      "questions" => { "type" => "string" }
    }
  }.freeze

  # Structured result for the REGISTRATION flow, where CALL-E walks a volunteer
  # through the full 5-step application form over the phone. Mirrors
  # VolunteerApplication fields (see CalleRegistration). Multi-select fields are
  # captured as free text (comma-separated) and normalized server-side, which is
  # more reliable for a voice agent than JSON arrays.
  REGISTRATION_RESULT_SCHEMA = {
    "type" => "object",
    "properties" => {
      "first_name" => { "type" => "string" },
      "last_name" => { "type" => "string" },
      "email" => { "type" => "string" },
      "phone" => { "type" => "string" },
      "date_of_birth" => { "type" => "string" },
      "country" => { "type" => "string" },
      "volunteer_type" => { "type" => "string" },
      "travel_companion" => { "type" => "string" },
      "volunteer_work" => { "type" => "string" },
      "other_volunteer_work" => { "type" => "string" },
      "preferred_locations" => { "type" => "string" },
      "project_title" => { "type" => "string" },
      "preferred_start_date" => { "type" => "string" },
      "planned_duration" => { "type" => "string" },
      "skills_education" => { "type" => "string" },
      "motivation" => { "type" => "string" },
      "comments" => { "type" => "string" },
      "gdpr_consent" => { "type" => "boolean" },
      "preferred_interview_at" => { "type" => "string" },
      "preferred_callback_at" => { "type" => "string" },
      "questions" => { "type" => "string" }
    }
  }.freeze

  class << self
    def start_call(to_phone:, goal:, language: nil, region: nil, result_schema: nil, api_key: nil)
      new.start_call(to_phone: to_phone, goal: goal, language: language, region: region, result_schema: result_schema, api_key: api_key)
    end

    def call_status(run_id, api_key: nil)
      new.call_status(run_id, api_key: api_key)
    end

    # The OUTBOUND read-back goal used by InboundReadInboxJob: greet the verified
    # volunteer by name and read their unread messages verbatim. Kept here (not
    # in the job) so the wording is a single, paste-ready source of truth.
    def read_inbox_goal(name:, messages:)
      <<~TXT.squish
        You are calling on behalf of OpenmindProjects. Open the call by greeting
        #{name} by name and confirming you are speaking with #{name}. Explain
        that you are calling back to read their unread inbox messages, as they
        requested on the volunteer hotline. Read each message below out loud, one
        at a time, and pause briefly after each so they can take notes:

        #{messages}

        After reading, ask if they would like you to repeat any message, and
        whether they have any questions. Do not invent, summarize, or skip any
        message — read them exactly as written. End by thanking them warmly.
      TXT
    end
  end

  # Create an asynchronous call task. Returns a Result whose +run_id+ is the
  # CALL-E call task id (starts with "call_"), used later to poll status.
  def start_call(to_phone:, goal:, language: nil, region: nil, result_schema: nil, api_key: nil)
    return dry_run_start if dry_run?

    routing = routing_for(to_phone)
    language ||= routing[:locale] || DEFAULT_LOCALE
    region ||= routing[:region]

    recipient = { "phones" => [to_phone] }
    recipient["locale"] = language if language.present?
    recipient["region"] = region if region.present?

    body = {
      "task" => goal,
      "recipients" => [recipient],
      "recipient_result_schema" => (result_schema || RECIPIENT_RESULT_SCHEMA),
      "metadata" => {
        "source" => ENV.fetch("CALLE_SOURCE", "openmindprojects"),
        "integration" => ENV.fetch("CALLE_INTEGRATION", "mindy_call_booking")
      }
    }

    result_from_task(post_json("/v1/calls", body, api_key))
  end

  # Fetch the current state of a call task by id.
  def call_status(run_id, api_key: nil)
    return dry_run_status if dry_run?

    result_from_task(get_json("/v1/calls/#{run_id}", api_key))
  end

  def dry_run?
    # Dry-run by default in every environment. Real calls require an explicit
    # CALLE_DRY_RUN=0 so no billed call can ever fire accidentally.
    ENV["CALLE_DRY_RUN"] != "0"
  end

  def max_wait_seconds
    Integer(ENV.fetch("CALLE_MAX_WAIT_SECONDS", DEFAULT_MAX_WAIT_SECONDS))
  end

  def poll_interval_seconds
    Integer(ENV.fetch("CALLE_POLL_INTERVAL_SECONDS", DEFAULT_POLL_INTERVAL_SECONDS))
  end

  # Lightweight auth check that never places a call. An authenticated GET to a
  # sentinel call id returns 404 (auth OK) rather than 401/403 (bad key). Used by
  # the host integrations "Test key" action to validate a BYO key.
  def key_valid?(api_key_override = nil)
    get_json("/v1/calls/calle_api_key_probe", api_key_override)
    true
  rescue Error => e
    msg = e.message
    return false if msg.include?(" 401") || msg.include?(" 403")

    # 404 (sentinel id doesn't exist) proves the request authenticated. Network
    # errors are reported as "not invalid" so a bad key isn't blamed for a
    # transient connectivity failure.
    true
  end

  private

  # Auto-detect CALL-E routing (region + spoken locale) from an E.164 number.
  # Falls back to DEFAULT_LOCALE with no region hint for unmapped countries.
  def routing_for(phone)
    code = country_code(phone)
    code ? COUNTRY_ROUTING[code] : {}
  end

  def country_code(phone)
    digits = phone.to_s.sub(/\A\+/, "")
    COUNTRY_ROUTING.keys.find { |code| digits.start_with?(code) }
  end

  # Map a CallTask JSON payload to a normalized Result.
  def result_from_task(task)
    Result.new(
      run_id: task["id"],
      status: normalize_status(task["status"]),
      summary: task["summary"],
      transcript: extract_transcript(task["recipients"]),
      callee_number: extract_callee(task["recipients"]),
      duration_seconds: extract_duration(task),
      structured_result: extract_structured_result(task),
      activity: []
    )
  end

  # The API uses lowercase lifecycle statuses; the app's Result::TERMINAL uses
  # uppercase, so normalize here for a single comparison point.
  def normalize_status(api_status)
    api_status.to_s.upcase
  end

  def extract_transcript(recipients)
    turns = Array(recipients).flat_map do |r|
      Array(r["attempts"]).flat_map { |a| Array(a["transcript_turns"]) }
    end
    return nil if turns.empty?

    turns.map { |t| "#{t['speaker']}: #{t['text']}" }.join("\n")
  end

  def extract_callee(recipients)
    r = Array(recipients).first
    return nil if r.blank?

    Array(r["phones"]).first || Array(r["attempts"]).first&.dig("phone")
  end

  def extract_duration(task)
    started = task["created_at"]
    completed = task["completed_at"]
    return nil if started.blank? || completed.blank?

    [(Time.parse(completed) - Time.parse(started)).round, 0].max
  rescue ArgumentError, TypeError
    nil
  end

  # Per-recipient structured result (populated via recipient_result_schema);
  # falls back to the task-level structured_result for batch tasks.
  def extract_structured_result(task)
    recipient = Array(task["recipients"]).first
    recipient&.dig("structured_result") || task["structured_result"]
  end

  def dry_run_start
    Result.new(
      run_id: "dry-run-#{SecureRandom.hex(6)}",
      status: "RUNNING",
      dry_run: true,
      activity: [{ "message" => "[dry-run] call start requested", "ts" => Time.current.iso8601 }]
    )
  end

  def dry_run_status
    Result.new(
      status: "COMPLETED",
      summary: "[dry-run] This is a simulated CALL-E conversation. No real call was placed.",
      transcript: "[dry-run transcript]",
      duration_seconds: 0,
      dry_run: true,
      activity: [{ "message" => "[dry-run] call completed", "ts" => Time.current.iso8601 }]
    )
  end

  def post_json(path, body, api_key_override = nil)
    request_json(Net::HTTP::Post, path, body, api_key_override)
  end

  def get_json(path, api_key_override = nil)
    request_json(Net::HTTP::Get, path, nil, api_key_override)
  end

  def request_json(method_class, path, body, api_key_override = nil)
    uri = URI.join(base_url, path)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 10
    http.read_timeout = 30

    req = method_class.new(uri.request_uri)
    req["Authorization"] = "Bearer #{api_key(api_key_override)}"
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body) if body

    res = http.request(req)

    unless res.is_a?(Net::HTTPSuccess)
      raise Error, "CALL-E API #{res.code} for #{method_class::METHOD} #{path}: #{res.body.to_s.truncate(500)}"
    end

    JSON.parse(res.body)
  rescue JSON::ParserError => e
    raise Error, "Invalid JSON from CALL-E API: #{e.message}"
  rescue Errno::ECONNREFUSED, SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise Error, "CALL-E API connection error: #{e.message}"
  end

  def api_key(override = nil)
    override.presence || ENV["CALLE_API_KEY"].presence || raise(Error, "CALLE_API_KEY is not set")
  end

  def base_url
    ENV["CALLE_BASE_URL"].presence || DEFAULT_BASE_URL
  end
end
