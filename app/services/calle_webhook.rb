# Parses a CALL-E inbound webhook payload into the fields needed to create a
# CallBooking. CALL-E delivers inbound call events using the same CallTask shape
# as the outbound API, but we tolerate a few common wrapper shapes (data / call /
# call_task / task) since the exact envelope is configured in the CALL-E
# dashboard. Payloads are treated as untrusted and read defensively.
class CalleWebhook
  def initialize(payload)
    @payload = payload || {}
  end

  # Only a successfully completed inbound call that captured a name and a phone
  # number should become a booking.
  def bookable?
    completed? && caller_phone.present? && name.present?
  end

  # True when this completed inbound call is a full registration call (the agent
  # walked the caller through the whole application form) rather than a simple
  # booking call.
  def registration?
    completed? && CalleRegistration.registration_call?(structured_result)
  end

  # Attributes handed to InboundRegistrationJob.
  def registration_attributes
    {
      "run_id" => call_id,
      "phone" => caller_phone,
      "structured_result" => structured_result,
      "summary" => summary,
      "transcript" => transcript
    }
  end
  def call_id
    first_present(data["id"], @payload["call_id"], @payload["id"])
  end

  def completed?
    data["status"].to_s.downcase == "completed"
  end

  def caller_phone
    first_present(
      @payload["from"], @payload["caller"], @payload["caller_number"],
      @payload["from_number"], recipient_phones.first
    )
  end

  def name
    structured_result["name"].to_s.strip.presence
  end

  def contact_pin
    structured_result["contact_pin"].to_s.strip.presence
  end

  def email
    structured_result["email"].to_s.strip.presence
  end

  def structured_result
    @structured_result ||= begin
      recipient = recipients.map { |r| r["structured_result"] }.find { |s| s.is_a?(Hash) }
      recipient || data["structured_result"] || {}
    end
  end

  def summary
    data["summary"].presence
  end

  def transcript
    turns = recipients.flat_map do |r|
      Array(r["attempts"]).flat_map { |a| Array(a["transcript_turns"]) }
    end
    return nil if turns.empty?

    turns.map { |t| "#{t['speaker']}: #{t['text']}" }.join("\n")
  end

  def preferred_at
    parse_time(structured_result["preferred_date_time"])
  end

  def purpose
    normalize_purpose(structured_result["purpose"])
  end

  # Attributes handed to InboundCallBookingJob.
  def booking_attributes
    {
      "run_id" => call_id,
      "phone" => caller_phone,
      "name" => name,
      "email" => email,
      "purpose" => purpose,
      "preferred_at" => preferred_at&.iso8601,
      "contact_pin" => contact_pin,
      "summary" => summary,
      "transcript" => transcript,
      "structured_result" => structured_result
    }
  end

  # True when this completed inbound call asked the agent to read the caller's
  # unread inbox messages (the third dispatcher option).
  def read_inbox?
    completed? && read_inbox_intent?(structured_result)
  end

  # Attributes handed to InboundReadInboxJob.
  def read_inbox_attributes
    {
      "run_id" => call_id,
      "email" => email,
      "contact_pin" => contact_pin,
      "caller_phone" => caller_phone,
      "summary" => summary,
      "transcript" => transcript,
      "structured_result" => structured_result
    }
  end

  private

  def data
    @data ||= first_present(
      @payload["data"], @payload["call"], @payload["call_task"], @payload["task"], @payload
    )
  end

  def recipients
    Array(data["recipients"])
  end

  def recipient_phones
    recipients.flat_map { |r| Array(r["phones"]) }
  end

  def first_present(*values)
    values.find { |v| v.present? }
  end

  # The read-inbox intent is signalled by a `read_inbox` flag in the structured
  # result (the dispatcher prompt's third option), or by an intent/purpose value
  # that mentions reading the inbox. Both shapes are read defensively.
  def read_inbox_intent?(result)
    return false unless result.is_a?(Hash)

    flag = result["read_inbox"]
    return true if flag == true || flag.to_s.downcase.in?(%w[true yes 1 read_inbox read_inbox_message read_my_inbox])

    %w[intent purpose request_type].any? do |key|
      value = result[key].to_s.downcase
      value.include?("read") && value.include?("inbox")
    end
  end

  def parse_time(value)
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # Map the agent's free-text purpose back to one of CallBooking::PURPOSES.
  def normalize_purpose(value)
    v = value.to_s.downcase.strip
    return "volunteer" if v.include?("onsite") || v.include?("internship") || v.include?("in person")
    return "volunteering_info" if v.include?("online") || v.include?("remote")
    return "partnership" if v.include?("partner")

    CallBooking::PURPOSES.include?(v) ? v : "general"
  end
end
