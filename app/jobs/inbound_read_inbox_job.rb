# Turns a completed inbound CALL-E call that requested "read my inbox" into a
# verified read-back: verify the caller's identity (email + PIN + ANI), look up
# their unread host→volunteer messages, and place an OUTBOUND call whose goal
# contains the messages verbatim. Zero content is read until verification passes.
#
# Idempotency is guaranteed by InboundReadInboxRequest's unique +run_id+, so a
# redelivered webhook is a no-op.
class InboundReadInboxJob < ApplicationJob
  queue_as :default

  def perform(attributes)
    attributes = attributes.symbolize_keys
    run_id = attributes[:run_id].presence

    return if run_id && InboundReadInboxRequest.exists?(run_id: run_id)

    email = attributes[:email].to_s.strip.presence
    pin = attributes[:contact_pin].to_s.strip
    caller_phone = attributes[:caller_phone].to_s.strip.presence

    # Outbound-initiated read-backs (host approves a "read my inbox" callback)
    # pass require_ani: false so a volunteer who changed phones can still verify
    # by email + PIN. Inbound webhook read-backs keep the secure default (true).
    require_ani = attributes.fetch(:require_ani, VolunteerInboxService::REQUIRE_ANI_FOR_INBOX)
    result = VolunteerInboxService.verify(email: email, pin: pin, caller_phone: caller_phone, require_ani: require_ani)

    unless result.verified?
      record(run_id, email, "failed", result.reason.to_s)
      Rails.logger.info "[InboundReadInbox] verification failed (#{result.reason}) for #{email || 'blank email'}"
      return
    end

    messages = VolunteerInboxService.unread_messages_for(email)
    if messages.blank?
      record(run_id, email, "no_messages")
      Rails.logger.info "[InboundReadInbox] no unread messages for #{email} run_id=#{run_id}"
      return
    end

    place_read_back_call(email, caller_phone, messages)
    record(run_id, email, "verified")
    Rails.logger.info "[InboundReadInbox] verified email=#{email} run_id=#{run_id} messages=#{messages.size}"
  end

  private

  def place_read_back_call(email, caller_phone, messages)
    name = VolunteerInboxService.volunteer_name(email) || "there"
    # Dry-run by default: a real call is only placed when CALLE_DRY_RUN=0.
    goal = CalleClient.read_inbox_goal(name: name, messages: messages)
    result = CalleClient.start_call(to_phone: caller_phone, goal: goal)
    Rails.logger.info "[InboundReadInbox] read-back placed email=#{email} phone=#{caller_phone} run_id=#{result.run_id} dry_run=#{result.dry_run?}"
  end

  def record(run_id, email, status, reason = nil)
    return if run_id.blank?

    InboundReadInboxRequest.create!(
      run_id: run_id,
      email: email,
      status: status,
      verification_reason: reason
    )
  end
end
