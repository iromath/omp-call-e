# Places an OUTBOUND CALL-E voice call when a host approves and dispatches a
# goal-linked task (volunteer onboarding or feedback/review). Unlike the generic
# callback path (CallbackCallJob), there is no CallbackRequest — the drafted
# script lives on the HostTask description and the phone number is resolved from
# the linked volunteer application/profile.
#
# Runs the full lifecycle synchronously in one job (start -> poll -> persist),
# and must stay on a worker queue (never a request fiber) because CalleClient
# blocks on HTTP.
class HostTaskVoiceCallJob < ApplicationJob
  queue_as :default

  def perform(host_task_id)
    task = HostTask.find_by(id: host_task_id)
    return if task.nil? || task.volunteer_phone.blank?

    task.update!(status: "in_progress")

    # Bill this call to the task's host organization when it has configured its
    # own CALL-E key (bring-your-own-key); otherwise fall back to the global key.
    org_key = task.organization_profile&.calle_api_key

    result = CalleClient.start_call(
      to_phone: task.volunteer_phone,
      goal: task.voice_goal,
      api_key: org_key,
      result_schema: CalleClient::RECIPIENT_RESULT_SCHEMA
    )
    run_id = result.run_id

    Rails.logger.info "[HostTaskVoiceCall] started task=#{task.id} phone=#{task.volunteer_phone} run_id=#{run_id} dry_run=#{result.dry_run?}"

    client = CalleClient.new
    deadline = Time.current + client.max_wait_seconds

    loop do
      status = CalleClient.call_status(run_id, api_key: org_key)

      if status.terminal?
        task.apply_voice_result!(status)
        Rails.logger.info "[HostTaskVoiceCall] finished task=#{task.id} run_id=#{run_id} status=#{status.status} dry_run=#{status.dry_run?}"
        return
      end

      break if Time.current >= deadline

      sleep(client.poll_interval_seconds)
    end

    task.reopen_voice_dispatch!
    Rails.logger.warn "[HostTaskVoiceCall] call #{run_id} timed out before reaching a terminal status."
  rescue CalleClient::Error => e
    task&.reopen_voice_dispatch!
    Rails.logger.error "[HostTaskVoiceCall] CALL-E error: #{e.message}"
  end
end
