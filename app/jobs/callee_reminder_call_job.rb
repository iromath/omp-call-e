# Places the CALL-E follow-up reminder call after a self-serve appointment has
# been booked. It confirms the volunteer received the appointment email, answers
# their remaining questions, and — if the email was missed — escalates to Mindy
# so the host team gets an urgent task with a resend draft.
#
# Runs the full lifecycle synchronously inside a single background job: start
# the call, poll to a terminal status, then persist + escalate. It must stay on
# a worker queue (never a request fiber) because CalleClient blocks.
class CalleeReminderCallJob < ApplicationJob
  queue_as :default

  def perform(call_booking_id)
    booking = CallBooking.find_by(id: call_booking_id)
    return if booking.blank?

    # Dry-run must place no real call and leave no side effects on a real
    # booking (status, Meet attendee, escalation) — log and stop.
    if CalleClient.new.dry_run?
      Rails.logger.info "[CalleeReminder] dry-run — skipping follow-up call for booking #{booking.id} (no billed call, no side effects)"
      return
    end

    booking.update!(status: "calling")

    result = CalleClient.start_call(to_phone: booking.phone, goal: booking.follow_up_call_goal)
    run_id = result.run_id
    booking.update!(run_id: run_id) if run_id.present?

    Rails.logger.info "[CalleeReminder] started booking=#{booking.id} phone=#{booking.phone} run_id=#{run_id}"

    client = CalleClient.new
    deadline = Time.current + client.max_wait_seconds

    loop do
      status = CalleClient.call_status(run_id)

      if status.terminal?
        booking.apply_terminal_result!(status)
        add_meet_attendee(booking)
        booking.escalate_missed_email! if booking.escalation_needed?
        Rails.logger.info "[CalleeReminder] finished booking=#{booking.id} run_id=#{run_id} status=#{status.status}"
        return
      end

      break if Time.current >= deadline

      sleep(client.poll_interval_seconds)
    end

    booking.update!(status: "failed", summary: "Call timed out before reaching a terminal status.")
    Rails.logger.warn "[CalleeReminder] call #{run_id} timed out before reaching a terminal status."
  rescue CalleClient::Error => e
    booking.update!(status: "failed", summary: "CALL-E error: #{e.message}")
    Rails.logger.error "[CalleeReminder] CALL-E error: #{e.message}"
  end

  private

  # If the follow-up call captured an email we didn't have when the event was
  # created, add the volunteer as an attendee so they receive the Meet invite.
  def add_meet_attendee(booking)
    return if booking.email.blank? || booking.google_event_id.blank?

    GoogleCalendarService.new.add_attendee(booking.google_event_id, booking.email, calendar_id: CallBooking.calendar_id_for(booking.purpose))
  end
end
