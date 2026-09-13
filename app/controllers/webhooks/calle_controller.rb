module Webhooks
  # CALL-E inbound webhook (server-to-server): fires when a volunteer calls our
  # toll-free number and the CALL-E agent has finished guiding them through a
  # booking. A completed call is handed to InboundCallBookingJob, which creates a
  # CallBooking and reuses the same calendar/Meet/email pipeline as the web form.
  class CalleController < ApplicationController
    skip_before_action :verify_authenticity_token
    skip_before_action :allow_browser, raise: false

    # POST /webhooks/calle
    def create
      body = request.body.read
      payload = JSON.parse(body)

      return head(:unauthorized) unless valid_event?(payload, body)

      event = CalleWebhook.new(payload)
      Rails.logger.info "[Calle Webhook] call_id=#{event.call_id} completed=#{event.completed?} read_inbox=#{event.read_inbox?} registration=#{event.registration?} bookable=#{event.bookable?}"

      if event.read_inbox?
        InboundReadInboxJob.perform_later(event.read_inbox_attributes)
      elsif event.registration?
        InboundRegistrationJob.perform_later(event.registration_attributes)
      elsif event.bookable?
        InboundCallBookingJob.perform_later(event.booking_attributes)
      end

      head :ok
    rescue JSON::ParserError => e
      Rails.logger.error "[Calle Webhook] invalid JSON: #{e.message}"
      head :bad_request
    end

    private

    # CALL-E webhook delivery is currently UNSIGNED: there is no webhook
    # secret, CALL-E-Timestamp, or CALL-E-Signature header. Integrity is
    # established by requiring the CALL-E-Event-Id header and rejecting the
    # request when it does not match the body event `id`. The legacy HMAC check
    # is kept only as an optional extra when both CALLE_WEBHOOK_SECRET and a
    # signature header are present — it is never required.
    def valid_event?(payload, body)
      event_id = request.headers["CALL-E-Event-Id"].presence
      body_id = payload["id"].presence || payload.dig("data", "id").presence
      return false if event_id.blank? || body_id.blank?
      return false unless ActiveSupport::SecurityUtils.secure_compare(event_id, body_id)

      secret = ENV["CALLE_WEBHOOK_SECRET"].presence
      signature = request.headers["X-Calle-Signature"].presence ||
                  request.headers["X-Signature"].presence ||
                  request.headers["X-Hub-Signature-256"].presence
      return true if secret.blank? || signature.blank?

      expected = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
      ActiveSupport::SecurityUtils.secure_compare(signature.to_s.sub(/\Asha256=/, "").downcase, expected)
    end
  end
end
