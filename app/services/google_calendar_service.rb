# Creates Google Calendar events with an attached Google Meet conference.
#
# Google Meet is not a separate API — an event with `conferenceData.createRequest`
# makes Google auto-generate a Meet link (`hangoutLink`). Events are created on a
# single shared OpenmindProjects account so the public volunteer flow needs no
# per-volunteer OAuth.
class GoogleCalendarService
  SCOPES = ["https://www.googleapis.com/auth/calendar.events"].freeze
  # Full calendar scope, needed only to create secondary calendars. Kept separate
  # so runtime event operations stay on the narrower `calendar.events` scope; a
  # one-time setup token uses this scope, then is discarded.
  SETUP_SCOPES = ["https://www.googleapis.com/auth/calendar"].freeze
  TOKEN_URI = "https://oauth2.googleapis.com/token".freeze
  DEFAULT_OWNER_EMAIL = "hello@openmindprojects.net".freeze
  DEFAULT_DURATION_MINUTES = 30

  # The calendar the appointment is written to. "primary" is the primary
  # calendar of the authenticated account (hello@openmindprojects.net). Set
  # GOOGLE_CALENDAR_ID to target a specific secondary calendar instead.
  def self.calendar_id
    ENV["GOOGLE_CALENDAR_ID"].presence || "primary"
  end

  def initialize(refresh_token: nil, scope: SCOPES)
    # The OAuth client (ID + secret) is shared across Google APIs, so fall back
    # to the Gmail client already configured. Only the refresh token is API-
    # specific: Calendar needs one authorized for the calendar.events scope.
    @client_id     = ENV["GOOGLE_CALENDAR_CLIENT_ID"].presence || ENV["GMAIL_SYNC_CLIENT_ID"].presence || Rails.application.credentials.dig(:google_calendar, :client_id)
    @client_secret = ENV["GOOGLE_CALENDAR_CLIENT_SECRET"].presence || ENV["GMAIL_SYNC_CLIENT_SECRET"].presence || Rails.application.credentials.dig(:google_calendar, :client_secret)
    @refresh_token = refresh_token.presence || ENV["GOOGLE_CALENDAR_REFRESH_TOKEN"].presence || Rails.application.credentials.dig(:google_calendar, :refresh_token)

    if @client_id.blank? || @refresh_token.blank?
      Rails.logger.warn "[GoogleCalendar] Calendar credentials not configured. Event creation disabled."
      @disabled = true
      return
    end

    @service = Google::Apis::CalendarV3::CalendarService.new
    @service.authorization = Google::Auth::UserRefreshCredentials.new(
      client_id: @client_id,
      client_secret: @client_secret,
      refresh_token: @refresh_token,
      scope: scope,
      token_credential_uri: TOKEN_URI
    )
    @disabled = false
  end

  def disabled?
    @disabled
  end

  # Create an event with a Meet conference, tagged with the booking identity so
  # the Meet link is tied to a specific appointment. Returns a hash with the
  # created event id, Meet link, and calendar link (nil when disabled or the API
  # call fails).
  def create_event(summary:, start_time:, duration_minutes: DEFAULT_DURATION_MINUTES, description: nil,
                   attendee_emails: [], calendar_id: self.class.calendar_id, extended_properties: {})
    return { event_id: nil, meet_link: nil, html_link: nil } if @disabled

    event = Google::Apis::CalendarV3::Event.new(
      summary: summary,
      description: description.presence,
      start: Google::Apis::CalendarV3::EventDateTime.new(date_time: start_time.iso8601),
      end: Google::Apis::CalendarV3::EventDateTime.new(date_time: (start_time + duration_minutes.minutes).iso8601),
      conference_data: Google::Apis::CalendarV3::ConferenceData.new(
        create_request: Google::Apis::CalendarV3::CreateConferenceRequest.new(
          request_id: SecureRandom.uuid,
          conference_solution_key: Google::Apis::CalendarV3::ConferenceSolutionKey.new(type: "hangoutsMeet")
        )
      ),
      attendees: attendee_emails.filter_map { |email|
        Google::Apis::CalendarV3::EventAttendee.new(email: email) if email.present?
      },
      extended_properties: build_extended_properties(extended_properties)
    )

    created = @service.insert_event(calendar_id, event, conference_data_version: 1, send_updates: "all")
    {
      event_id: created.id,
      meet_link: created.hangout_link.presence || video_entry_point(created),
      html_link: created.html_link
    }
  rescue Google::Apis::ClientError => e
    Rails.logger.error "[GoogleCalendar] Failed to create event: #{e.message}"
    { event_id: nil, meet_link: nil, html_link: nil }
  end

  # Move an existing event to a new start time (keeps the same Meet link).
  def update_event(event_id, start_time:, duration_minutes: DEFAULT_DURATION_MINUTES, calendar_id: self.class.calendar_id)
    return { event_id: nil, meet_link: nil, html_link: nil } if @disabled || event_id.blank?

    event = Google::Apis::CalendarV3::Event.new(
      start: Google::Apis::CalendarV3::EventDateTime.new(date_time: start_time.iso8601),
      end: Google::Apis::CalendarV3::EventDateTime.new(date_time: (start_time + duration_minutes.minutes).iso8601)
    )

    updated = @service.update_event(calendar_id, event_id, event, send_updates: "all")
    {
      event_id: updated.id,
      meet_link: updated.hangout_link.presence || video_entry_point(updated),
      html_link: updated.html_link
    }
  rescue Google::Apis::ClientError => e
    Rails.logger.error "[GoogleCalendar] Failed to update event #{event_id}: #{e.message}"
    { event_id: nil, meet_link: nil, html_link: nil }
  end

  # Delete an event (used when a booking is cancelled or rescheduled).
  def cancel_event(event_id, calendar_id: self.class.calendar_id)
    return false if @disabled || event_id.blank?

    @service.delete_event(calendar_id, event_id)
    true
  rescue Google::Apis::ClientError => e
    Rails.logger.error "[GoogleCalendar] Failed to cancel event #{event_id}: #{e.message}"
    false
  end

  # Add an attendee to an existing event. Used when the call captures the
  # volunteer's email after the event was already created, so they receive the
  # Meet invite. Idempotent — no-op if already an attendee.
  def add_attendee(event_id, email, calendar_id: self.class.calendar_id)
    return false if @disabled || event_id.blank? || email.blank?

    event = @service.get_event(calendar_id, event_id)
    current = event.attendees.to_a.map(&:email).compact
    return true if current.include?(email)

    event.attendees = (current + [email]).uniq.map { |e| Google::Apis::CalendarV3::EventAttendee.new(email: e) }
    @service.update_event(calendar_id, event_id, event, send_updates: "all")
    true
  rescue Google::Apis::ClientError => e
    Rails.logger.error "[GoogleCalendar] Failed to add attendee #{email} to event #{event_id}: #{e.message}"
    false
  end

  # List slot events in a calendar within [time_min, time_max], expanding
  # recurring events into daily occurrences (singleEvents=true). Returns an
  # array of { start:, end: } (DateTime, or Date for all-day events) so callers
  # can format the windows. Returns [] when disabled or the API call fails.
  def list_events(calendar_id:, time_min:, time_max:)
    return [] if @disabled || calendar_id.blank?

    response = @service.list_events(
      calendar_id,
      single_events: true,
      order_by: "startTime",
      time_min: time_min,
      time_max: time_max
    )

    (response.items || []).filter_map do |item|
      start_at = item.start&.date_time || item.start&.date
      end_at = item.end&.date_time || item.end&.date
      next if start_at.blank? || end_at.blank?

      { start: start_at, end: end_at }
    end
  rescue Google::Apis::ClientError => e
    Rails.logger.error "[GoogleCalendar] Failed to list events for #{calendar_id}: #{e.message}"
    []
  end

  # Create a new secondary calendar and return its id. Requires the full
  # `calendar` scope, so this is intended for the one-time setup task only —
  # which passes a separate calendar-scoped token — not for runtime use.
  def create_calendar(summary:, time_zone: "Asia/Bangkok")
    return nil if @disabled

    calendar = Google::Apis::CalendarV3::Calendar.new(summary: summary, time_zone: time_zone)
    @service.insert_calendar(calendar)&.id
  rescue Google::Apis::ClientError => e
    Rails.logger.error "[GoogleCalendar] Failed to create calendar #{summary}: #{e.message}"
    nil
  end

  # Create a recurring weekly "availability" event on a calendar and return its
  # id. Only needs the calendar.events scope, so this runs with the normal
  # runtime credentials (unlike create_calendar, which needs the full scope).
  def create_availability_event(calendar_id:, summary:, start_time:, end_time:, recurrence:)
    return nil if @disabled || calendar_id.blank?

    event = Google::Apis::CalendarV3::Event.new(
      summary: summary,
      start: Google::Apis::CalendarV3::EventDateTime.new(date_time: start_time.iso8601, time_zone: "Asia/Bangkok"),
      end: Google::Apis::CalendarV3::EventDateTime.new(date_time: end_time.iso8601, time_zone: "Asia/Bangkok"),
      recurrence: Array(recurrence)
    )
    @service.insert_event(calendar_id, event)&.id
  rescue Google::Apis::ClientError => e
    Rails.logger.error "[GoogleCalendar] Failed to create availability event in #{calendar_id}: #{e.message}"
    nil
  end

  private

  def build_extended_properties(props)
    return nil if props.blank?

    Google::Apis::CalendarV3::Event::ExtendedProperties.new(private: props.stringify_keys)
  end

  def video_entry_point(event)
    event.conference_data&.entry_points&.find { |ep| ep.entry_point_type == "video" }&.uri
  end
end
