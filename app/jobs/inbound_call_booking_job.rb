# Turns a completed inbound CALL-E call into a real booking. The caller already
# gave their details to the agent, so we create the CallBooking and hand it to
# BookAppointmentJob (calendar event + Meet link + email). The follow-up reminder
# call is skipped because the caller just finished that conversation.
class InboundCallBookingJob < ApplicationJob
  queue_as :default

  def perform(attributes)
    attributes = attributes.symbolize_keys

    # Idempotency: a redelivered webhook for the same CALL-E call must not create
    # a second booking. run_id has a unique index, so this is also a safety net.
    return if attributes[:run_id].present? && CallBooking.exists?(run_id: attributes[:run_id])

    # Verify the caller's contact PIN when one was captured. This is the
    # authentication gate for hotline self-service: a returning volunteer who
    # provides the wrong PIN is recorded as not verified (soft-fail) so a human
    # can follow up, while the booking itself is still captured.
    structured_result = (attributes[:structured_result] || {}).dup
    if attributes[:contact_pin].present?
      structured_result["pin_verified"] =
        VolunteerContactPin.authenticate(attributes[:email], attributes[:contact_pin])
    end

    booking = CallBooking.create!(
      name: attributes[:name],
      phone: attributes[:phone],
      email: attributes[:email].presence,
      purpose: attributes[:purpose].presence || "general",
      preferred_at: resolve_slot(attributes[:preferred_at]),
      run_id: attributes[:run_id].presence,
      summary: attributes[:summary].presence,
      transcript: attributes[:transcript].presence,
      structured_result: structured_result
    )

    BookAppointmentJob.perform_later(booking.id, false)

    Rails.logger.info "[InboundCallBooking] created booking=#{booking.id} number=#{booking.booking_number} run_id=#{booking.run_id} purpose=#{booking.purpose}"
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error "[InboundCallBooking] rejected: #{e.record.errors.full_messages.join('; ')}"
  end

  private

  # Use the caller's requested slot if it's still free; otherwise fall back to
  # the next open slot (or nil, which BookAppointmentJob treats as "soon").
  def resolve_slot(raw)
    slot = parse_time(raw)
    return slot if slot.present? && CallBooking.active.where(preferred_at: slot).none?

    CallBooking.next_available_slot
  end

  def parse_time(value)
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
