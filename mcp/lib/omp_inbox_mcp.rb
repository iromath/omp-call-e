# frozen_string_literal: true

# OpenmindProjects Inbox MCP server — the reusable tool surface behind "Bridge
# #2" (see docs/call-e-inbox-readback-plan.md §7).
#
# This module implements a minimal, dependency-free MCP (Model Context Protocol)
# server over stdio JSON-RPC 2.0. It exposes a small set of read-only tools that
# let an external agent host (Claude Code, Codex, …) ask "what does this
# volunteer's inbox say?" or "what's their application status?" — subject to the
# same multi-factor identity gate the phone hotline uses.
#
# Every tool delegates to +VolunteerInboxService+, the single security gate:
#   * the caller must present a known email + correct 6-digit contact PIN, and
#   * wrong PINs feed the progressive lockout in VolunteerContactPin.
#
# There is deliberately NO caller-phone (ANI) factor here: an MCP tool has no
# telephony ANI, so we relax ANI and rely on PIN + rate-limit. The hotline path
# keeps ANI enforcement on (VolunteerInboxService::REQUIRE_ANI_FOR_INBOX).
module OmpInboxMcp
  # The MCP protocol version we advertise. Clients negotiate from here.
  PROTOCOL_VERSION = "2024-11-05"

  # ── Tool registry ─────────────────────────────────────────────────────────
  #
  # Each entry is the JSON `tools/list` shape: a name, a human description, and
  # a JSON Schema for the arguments. The auth model is intentionally simple and
  # uniform: `email` is the (semi-public) lookup key, `pin` is the secret.
  TOOLS = [
    {
      name: "get_unread_messages",
      description: "Return a volunteer's unread host→volunteer inbox messages as plain text. " \
                   "Requires the volunteer's email address and 6-digit contact PIN; no content " \
                   "is returned unless the PIN verifies.",
      inputSchema: {
        type: "object",
        properties: {
          email: { type: "string", description: "Volunteer email address (lookup key)." },
          pin: { type: "string", description: "6-digit contact PIN." }
        },
        required: ["email", "pin"]
      }
    },
    {
      name: "get_application_status",
      description: "Return a volunteer's most recent application status as plain text. " \
                   "Requires the volunteer's email address and 6-digit contact PIN.",
      inputSchema: {
        type: "object",
        properties: {
          email: { type: "string", description: "Volunteer email address (lookup key)." },
          pin: { type: "string", description: "6-digit contact PIN." }
        },
        required: ["email", "pin"]
      }
    }
  ].freeze

  # A single JSON-RPC request/response cycle over stdio. Constructed with the
  # streams so it can be driven by a subprocess (stdin/stdout) or exercised
  # directly in a test by feeding it raw JSON lines.
  class Server
    def initialize(input: $stdin, output: $stdout)
      @input = input
      @output = output
      @output.sync = true
    end

    # Read newline-delimited JSON-RPC until stdin closes, writing one response
    # line per request. Notifications (no `id`) are consumed without a reply.
    def run
      while (line = @input.gets)
        line = line.strip
        next if line.empty?

        response = handle_line(line)
        next if response.nil?

        @output.write(JSON.generate(response) + "\n")
      end
    end

    # Parse + dispatch a single JSON-RPC line, returning the response hash (or
    # nil for notifications). Public so tests can exercise the protocol logic.
    def handle_line(line)
      id = nil
      request = JSON.parse(line)
      id = request["id"]
      return nil if id.nil? # notification — no response expected

      { jsonrpc: "2.0", id: id, result: dispatch(request["method"], request["params"]) }
    rescue JSON::ParserError => e
      { jsonrpc: "2.0", id: nil, error: { code: -32700, message: "Parse error: #{e.message}" } }
    rescue => e
      { jsonrpc: "2.0", id: id, error: { code: -32603, message: "Internal error: #{e.message}" } }
    end

    private

    def dispatch(method, params)
      case method
      when "initialize" then initialize_result
      when "ping" then {}
      when "tools/list" then { tools: TOOLS }
      when "tools/call" then call_tool(params)
      else raise "Unsupported method: #{method}"
      end
    end

    def initialize_result
      {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: { tools: {} },
        serverInfo: { name: "omp-inbox-mcp", version: "0.1.0" }
      }
    end

    def call_tool(params)
      name = params && params["name"]
      args = params && params["arguments"] || {}

      text =
        case name
        when "get_unread_messages" then get_unread_messages(args)
        when "get_application_status" then get_application_status(args)
        else raise "Unknown tool: #{name}"
        end

      { content: [{ type: "text", text: text }], isError: false }
    end

    # ── Tools ───────────────────────────────────────────────────────────────

    def get_unread_messages(args)
      email = args["email"].to_s.strip
      pin = args["pin"].to_s.strip

      result = verify_pin(email, pin)
      return verification_failure(result) unless result.verified?

      VolunteerInboxService.unread_messages_for(email).presence || "No unread messages."
    end

    def get_application_status(args)
      email = args["email"].to_s.strip
      pin = args["pin"].to_s.strip

      result = verify_pin(email, pin)
      return verification_failure(result) unless result.verified?

      canonical = VolunteerContactPin.canonicalize(email)
      application = VolunteerApplication.where("LOWER(email) = ?", canonical).order(created_at: :desc).first
      return "No application found for #{email}." if application.nil?

      [
        "Name: #{application.full_name}",
        "Status: #{application.stage_label}",
        "Type: #{application.application_type.presence || 'N/A'}",
        "Submitted: #{application.created_at&.strftime('%Y-%m-%d')}"
      ].join("\n")
    end

    # ── Auth gate ───────────────────────────────────────────────────────────

    # The single identity gate shared by every tool. PIN-only (no ANI) because
    # an MCP host has no telephony caller number; rate limiting still applies.
    def verify_pin(email, pin)
      VolunteerInboxService.verify(email: email, pin: pin, require_ani: false)
    end

    def verification_failure(result)
      "Verification failed (#{result.reason}). No data was returned."
    end
  end
end
