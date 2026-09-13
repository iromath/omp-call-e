# Multi-factor identity verification and unread-inbox lookup for the CALL-E
# "Read your Inbox message" hotline feature.
#
# The inbound CALL-E agent is a static prompt with no database access, so it
# captures the caller's email + 6-digit contact PIN (plus the caller's phone
# number when CALL-E delivers it) and hands them to us via the webhook. This
# service is the single security gate that decides whether the caller is who
# they claim to be BEFORE any inbox content (PII) is revealed.
#
# Factors (see docs/call-e-inbox-readback-plan.md §5):
#   1. a matching PIN record must exist for the email,
#   2. the record must not be locked out (rate limiting),
#   3. the PIN must match,
#   4. the caller's phone number (ANI) must match a phone on file.
class VolunteerInboxService
  # Result of a verification attempt. `verified?` is true only when every
  # required factor passed; `reason` is a stable symbol for logging/decisions.
  Result = Struct.new(:verified, :reason, keyword_init: true) do
    def verified?
      verified
    end
  end

  # Inbox content is sensitive, so the caller's phone number (ANI) must match a
  # phone on file for that volunteer. Set to false to allow PIN-only
  # verification, e.g. while CALL-E is not yet delivering ANI on inbound events.
  REQUIRE_ANI_FOR_INBOX = true

  # Number of trailing digits compared when matching caller ANI against a phone
  # on file, to tolerate country-code / formatting differences.
  ANI_MATCH_DIGITS = 10

  class << self
    def verify(email:, pin:, caller_phone: nil, require_ani: REQUIRE_ANI_FOR_INBOX)
      new.verify(email: email, pin: pin, caller_phone: caller_phone, require_ani: require_ani)
    end

    def unread_messages_for(email)
      new.unread_messages_for(email)
    end

    def volunteer_name(email)
      new.volunteer_name(email)
    end
  end

  # Verify a caller's identity. Returns a Result and reveals nothing about the
  # volunteer's data. A correct PIN resets the failure counter; a wrong PIN
  # increments it (and locks the identity once the threshold is reached).
  def verify(email:, pin:, caller_phone: nil, require_ani: REQUIRE_ANI_FOR_INBOX)
    canonical = VolunteerContactPin.canonicalize(email)
    return Result.new(verified: false, reason: :email_blank) if canonical.blank?

    record = VolunteerContactPin.find_by(email_canonical: canonical)
    return Result.new(verified: false, reason: :unknown_email) if record.nil?
    return Result.new(verified: false, reason: :locked) if record.locked?

    unless record.valid_pin?(pin)
      record.register_failed_attempt!
      return Result.new(verified: false, reason: :invalid_pin)
    end

    if require_ani
      return Result.new(verified: false, reason: :ani_missing) if caller_phone.blank?

      unless ani_matches?(canonical, caller_phone)
        record.reset_lock!
        return Result.new(verified: false, reason: :ani_mismatch)
      end
    end

    record.reset_lock!
    Result.new(verified: true, reason: :ok)
  end

  # Host → volunteer unread messages for +email+, formatted as a plain-text list
  # the outbound agent can read aloud. Empty string when there is no volunteer
  # account or no unread messages.
  def unread_messages_for(email)
    messages = unread_messages(email)
    return "" if messages.empty?

    messages.each_with_index.map do |message, index|
      sender = message.sender&.display_name.presence || "OpenmindProjects"
      "#{index + 1}. #{sender}: #{message.body}"
    end.join("\n")
  end

  # The volunteer's display name for +email+, used to greet them by name on the
  # read-back call. Nil when there is no volunteer account.
  def volunteer_name(email)
    canonical = VolunteerContactPin.canonicalize(email)
    return nil if canonical.blank?

    find_user(canonical)&.full_name.presence
  end

  private

  # The volunteer's User account for a canonicalized email, or nil. Inbox
  # content lives in Conversations keyed by the volunteer's User id.
  def find_user(canonical)
    User.find_by("LOWER(email) = ?", canonical)
  end

  # Unread messages addressed to the volunteer from anyone else (i.e. host-side).
  # System-generated messages are excluded so the agent only reads human content.
  def unread_messages(email)
    canonical = VolunteerContactPin.canonicalize(email)
    return [] if canonical.blank?

    user = find_user(canonical)
    return [] if user.nil?

    Message
      .joins(:conversation)
      .where(conversations: { volunteer_id: user.id })
      .where(read_at: nil)
      .where.not(sender_id: user.id)
      .where.not(message_type: "system")
      .order(created_at: :asc)
  end

  def ani_matches?(canonical, caller_phone)
    phones_on_file(canonical).any? { |stored| phone_match?(stored, caller_phone) }
  end

  # All phone numbers we have on file for a volunteer, from their applications
  # and past bookings. Used only for ANI matching; never returned to callers.
  def phones_on_file(canonical)
    app_phones = VolunteerApplication.where("LOWER(email) = ?", canonical).pluck(:phone, :whatsapp_phone).flatten
    booking_phones = CallBooking.where("LOWER(email) = ?", canonical).pluck(:phone)
    (app_phones + booking_phones).compact.map(&:to_s).reject(&:blank?).uniq
  end

  def phone_match?(stored, caller)
    d1 = phone_digits(stored)
    d2 = phone_digits(caller)
    return false if d1.blank? || d2.blank?
    return true if d1 == d2

    # Tolerate country-code / formatting differences by comparing trailing digits.
    return true if d1.length >= ANI_MATCH_DIGITS && d2.end_with?(d1.last(ANI_MATCH_DIGITS))
    return true if d2.length >= ANI_MATCH_DIGITS && d1.end_with?(d2.last(ANI_MATCH_DIGITS))

    false
  end

  def phone_digits(value)
    value.to_s.gsub(/\D/, "")
  end
end
