# Places the CALL-E callback call when a host approves and dispatches a
# "Call back ..." task. Unlike CalleeReminderCallJob / CalleRegistrationJob,
# this job is NOT tied to a VolunteerApplication — it simply calls the volunteer
# back so the AI can answer their questions and (optionally) help them start an
# application or book an interview.
#
# Runs the full lifecycle synchronously in one job (start -> poll -> persist),
# and must stay on a worker queue (never a request fiber) because CalleClient
# blocks on HTTP.
class CallbackCallJob < ApplicationJob
  queue_as :default

  def perform(callback_request_id)
    request = CallbackRequest.find_by(id: callback_request_id)
    return if request.nil? || request.phone.blank?

    request.update!(status: "calling")

    goal = request.booking_intent? ? request.booking_goal : request.call_goal

    result = CalleClient.start_call(
      to_phone: request.phone,
      goal: goal,
      result_schema: CalleClient::RECIPIENT_RESULT_SCHEMA
    )
    run_id = result.run_id
    request.update!(run_id: run_id) if run_id.present?

    Rails.logger.info "[CallbackCall] started request=#{request.id} phone=#{request.phone} run_id=#{run_id} dry_run=#{result.dry_run?}"

    client = CalleClient.new
    deadline = Time.current + [client.max_wait_seconds, 600].max

    loop do
      status = CalleClient.call_status(run_id)

      if status.terminal?
        request.apply_terminal_result!(status)
        Rails.logger.info "[CallbackCall] finished request=#{request.id} run_id=#{run_id} status=#{status.status} dry_run=#{status.dry_run?}"
        return
      end

      break if Time.current >= deadline

      sleep(client.poll_interval_seconds)
    end

    # A booking call can reach a terminal status right as the deadline elapses.
    # Poll once more before giving up so a slow call isn't marked failed when
    # CALL-E actually completed it.
    final_status = CalleClient.call_status(run_id)
    if final_status.terminal?
      request.apply_terminal_result!(final_status)
      Rails.logger.info "[CallbackCall] finished request=#{request.id} run_id=#{run_id} status=#{final_status.status} dry_run=#{final_status.dry_run?} (final poll)"
      return
    end

    request.update!(status: "failed")
    request.reopen_host_task!
    Rails.logger.warn "[CallbackCall] call #{run_id} timed out before reaching a terminal status."
  rescue CalleClient::Error => e
    request.update!(status: "failed")
    request.reopen_host_task!
    Rails.logger.error "[CallbackCall] CALL-E error: #{e.message}"
  end
end
