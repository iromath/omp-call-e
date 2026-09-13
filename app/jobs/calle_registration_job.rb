# Places an OUTBOUND CALL-E registration call: an applicant asks us to call them
# (from the web application form) and the AI walks them through the full 5-step
# volunteer application over the phone. On completion the structured result is
# persisted through CalleRegistration — the same validation/persistence used by
# the inbound path — so both channels share one pipeline.
#
# Runs the full lifecycle synchronously in one job (start -> poll -> persist),
# mirroring CalleeReminderCallJob. It must stay on a worker queue (never a
# request fiber) because CalleClient blocks on HTTP.
class CalleRegistrationJob < ApplicationJob
  queue_as :default

  def perform(callback_request_id)
    callback_request = CallbackRequest.find_by(id: callback_request_id)
    return if callback_request.nil? || callback_request.phone.blank?

    result = CalleClient.start_call(
      to_phone: callback_request.phone,
      goal: CalleRegistration.call_goal(name: callback_request.name, email: callback_request.email),
      result_schema: CalleClient::REGISTRATION_RESULT_SCHEMA
    )

    callback_request.update!(run_id: result.run_id, status: "calling")
    run_id = result.run_id

    Rails.logger.info "[CalleRegistration] started request=#{callback_request.id} phone=#{callback_request.phone} run_id=#{run_id} dry_run=#{result.dry_run?}"

    client = CalleClient.new
    # Registration calls run ~5 minutes, so give the poll loop enough headroom to
    # reach a terminal status rather than marking the request "failed" mid-call.
    deadline = Time.current + [client.max_wait_seconds, 600].max

    loop do
      status = CalleClient.call_status(run_id)

      if status.terminal?
        persist_registration!(run_id: run_id, phone: callback_request.phone, status: status, callback_request: callback_request)
        Rails.logger.info "[CalleRegistration] finished request=#{callback_request.id} run_id=#{run_id} status=#{status.status} dry_run=#{status.dry_run?}"
        return
      end

      break if Time.current >= deadline

      sleep(client.poll_interval_seconds)
    end

    callback_request.update!(status: "failed")
    callback_request.reopen_host_task!
    Rails.logger.warn "[CalleRegistration] call #{run_id} timed out before reaching a terminal status."
  rescue CalleClient::Error => e
    callback_request.update!(status: "failed")
    callback_request.reopen_host_task!
    Rails.logger.error "[CalleRegistration] CALL-E error: #{e.message}"
  end

  private

  # Only a completed call carries a usable structured result. Other terminal
  # outcomes (no answer, declined, failed, busy, voicemail) are logged and
  # produce no application. The callback request's status mirrors the outcome.
  def persist_registration!(run_id:, phone:, status:, callback_request:)
    # A dry-run call carries no real outcome; never mutate the request status or
    # persist an application from a simulation.
    if status.dry_run?
      Rails.logger.info "[CalleRegistration] dry-run result for request #{callback_request.id} — not persisting simulated outcome"
      return
    end

    completed = status.status.to_s.upcase == "COMPLETED"

    unless completed
      # No answer / voicemail / busy / error: schedule the next automatic retry
      # (no host approval) until the retry budget is exhausted.
      callback_request.update!(status: "failed")
      callback_request.auto_retry_or_reopen!
      Rails.logger.info "[CalleRegistration] call #{run_id} ended with #{status.status} — auto-scheduling retry."
      return
    end

    # The volunteer answered but asked us to call back at a better time. Close
    # this attempt and auto-schedule a follow-up task — no host approval needed.
    if reschedule_requested?(status.structured_result)
      reschedule_follow_up!(run_id: run_id, callback_request: callback_request, structured_result: status.structured_result)
      return
    end

    # A completed call that captured no registration data (the volunteer answered
    # but couldn't talk and gave no callback time) — schedule an automatic retry
    # instead of silently closing the task with no application.
    unless CalleRegistration.registration_call?(status.structured_result)
      callback_request.update!(status: "failed")
      callback_request.auto_retry_or_reopen!
      Rails.logger.info "[CalleRegistration] call #{run_id} completed without registration data — auto-scheduling retry."
      return
    end

    callback_request.update!(status: "completed")
    callback_request.current_host_task&.update!(status: "completed")

    result = CalleRegistration.submit!(
      run_id: run_id,
      phone: phone,
      structured_result: status.structured_result,
      summary: status.summary,
      transcript: status.transcript
    )

    return if result.persisted?

    Rails.logger.error "[CalleRegistration] rejected: #{result.errors.join('; ')}"
  end

  # True when the completed call captured a requested callback time (the
  # volunteer answered but asked to be called back later).
  def reschedule_requested?(structured_result)
    structured_result.is_a?(Hash) && structured_result["preferred_callback_at"].to_s.strip.present?
  end

  # Close the current attempt, auto-create a follow-up task, and schedule the
  # next CALL-E call at the requested time — no host approval required.
  def reschedule_follow_up!(run_id:, callback_request:, structured_result:)
    scheduled_at = parse_time(structured_result["preferred_callback_at"])

    callback_request.update!(status: "completed")
    callback_request.current_host_task&.update!(status: "completed")

    if scheduled_at.present? && scheduled_at.future?
      callback_request.update!(preferred_at: scheduled_at)
    end

    task = callback_request.create_follow_up_task!(scheduled_at: scheduled_at)

    if task && scheduled_at.present? && scheduled_at.future?
      CalleRegistrationJob.set(wait_until: scheduled_at).perform_later(callback_request.id)
      task.update!(status: "in_progress", dispatched_at: Time.current)
      Rails.logger.info "[CalleRegistration] call #{run_id} rescheduled — follow-up task #{task.id} auto-dispatched for #{scheduled_at}."
    elsif task
      Rails.logger.info "[CalleRegistration] call #{run_id} requested a callback but no future time — follow-up task #{task.id} left pending."
    else
      Rails.logger.warn "[CalleRegistration] call #{run_id} requested a callback but no follow-up task could be created."
    end
  end

  def parse_time(value)
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
