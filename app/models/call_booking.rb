# A volunteer-facing request for OpenmindProjects to call them back.
#
# The public "Book a call" form creates one of these; a background job then
# places an outbound CALL-E call and records the structured outcome here.
class CallBooking < ApplicationRecord
  include CalleVoice

  PURPOSES = %w[volunteer volunteering_info partnership general].freeze

  # Display metadata for the public booking form's event-type selector. Icons are
  # Phosphor icon names (rendered as `ph ph-<icon>`).
  PURPOSE_DETAILS = {
    "volunteer" => {
      label: "Onsite / Internship Interview",
      description: "An online call with our team for volunteers who have confirmed they will come and volunteer with OpenmindProjects onsite.",
      icon: "buildings",
      duration: "30 min"
    },
    "volunteering_info" => {
      label: "Online Volunteer Interview",
      description: "Volunteer with us online — such as English tutoring, coding, mentoring, or coaching students on our platform https://OpenSkills.Dev.",
      icon: "video-camera",
      duration: "30 min"
    },
    "partnership" => {
      label: "Partnership Interview",
      description: "Explore partnering with OpenmindProjects.",
      icon: "handshake",
      duration: "30 min"
    },
    "general" => {
      label: "General Callback",
      description: "Have a question or another topic to discuss.",
      icon: "chat-circle-text",
      duration: "30 min"
    }
  }.freeze

  # Coarse app-level lifecycle. The granular CALL-E outcome is kept in
  # +call_status+ (e.g. "NO_ANSWER", "VOICEMAIL").
  STATUSES = %w[scheduled calling completed failed rescheduled cancelled].freeze

  # Every appointment is a fixed-length slot.
  DURATION_MINUTES = 30

  # Single merged weekly availability (Asia/Bangkok), union of the onsite, online,
  # and partnership interview windows. Keys are Ruby weekdays (1=Mon .. 6=Sat);
  # values are [start, end] as "HH:MM". Sunday and Monday are unavailable.
  MERGED_AVAILABILITY = {
    2 => ["17:00", "20:30"], # Tuesday
    3 => ["17:15", "23:30"], # Wednesday
    4 => ["17:00", "23:30"], # Thursday
    5 => ["17:00", "20:00"]  # Friday
  }.freeze

  # Maps an interview purpose to the env var holding its dedicated Google
  # calendar id. `general` (callback) is intentionally absent — it stays "always
  # open" and has no slot calendar.
  PURPOSE_CALENDAR_ENV = {
    "volunteer"         => "GOOGLE_CAL_ONSITE",
    "volunteering_info" => "GOOGLE_CAL_ONLINE",
    "partnership"       => "GOOGLE_CAL_PARTNERSHIP"
  }.freeze

  # Bookings in these states no longer hold a slot, so their time is released.
  RELEASED_STATUSES = %w[cancelled rescheduled failed].freeze

  before_validation :normalize_phone, :set_token, :ensure_organization_profile

  # New bookings default to opting in to the follow-up confirmation call; the
  # public form renders this pre-checked.
  attribute :follow_up_consent, :boolean, default: true

  validates :name, presence: true
  validates :token, presence: true, uniqueness: true
  validates :phone, format: { with: /\A\+[1-9]\d{7,14}\z/,
                              message: "must be in E.164 format (e.g. +66812345678)" },
                    allow_blank: true
  validates :email, presence: true,
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :purpose, inclusion: { in: PURPOSES }
  validates :status, inclusion: { in: STATUSES }

  # Double-booking guard at the model layer (mirrored by a partial unique index).
  validate :preferred_at_available, on: :create

  scope :recent, -> { order(created_at: :desc) }
  scope :active, -> { where.not(status: RELEASED_STATUSES) }

  # Reschedule lineage: a replacement booking supersedes an earlier one. The
  # original is marked "rescheduled" and linked via +rescheduled_from_id+.
  belongs_to :rescheduled_from, class_name: "CallBooking", optional: true
  has_many :rescheduled_bookings, class_name: "CallBooking",
           foreign_key: :rescheduled_from_id, dependent: :nullify

  # Optional link back to the VolunteerApplication a CALL-E registration call
  # created, so the voice path and the web form share one pipeline.
  belongs_to :volunteer_application, optional: true

  # Owning host organization, resolved at creation so the Meeting Schedule
  # dashboard and staff tasks can be scoped per-org (mirrors HostTask / 
  # VolunteerApplication organization scoping).
  belongs_to :organization_profile, optional: true

  # The logged-in volunteer account that owns this interview booking (when the
  # public form was submitted while signed in, or backfilled by email).
  belongs_to :user, optional: true

  after_create :assign_booking_number

  class << self
    # The Google calendar id an appointment of this purpose is written to. For
    # the interview types this is the dedicated per-type calendar (falling back
    # to GOOGLE_CALENDAR_ID / primary until the calendar is configured); for
    # `general` there is no slot calendar, so it uses the default calendar.
    def calendar_id_for(purpose)
      env_key = PURPOSE_CALENDAR_ENV[purpose.to_s]
      return GoogleCalendarService.calendar_id if env_key.blank?

      ENV[env_key].presence || GoogleCalendarService.calendar_id
    end

    # True when the type has a dedicated availability calendar configured, so we
    # read real slot events from Google instead of the hardcoded windows.
    def availability_calendar_configured?(purpose)
      env_key = PURPOSE_CALENDAR_ENV[purpose.to_s]
      env_key.present? && ENV[env_key].present?
    end

    # Availability windows for a Bangkok date as a list of [start, end] "HH:MM"
    # strings. Reads the type's Google calendar when configured; otherwise falls
    # back to MERGED_AVAILABILITY so booking still works before the calendars exist.
    def availability_for(date, purpose: nil)
      return google_availability_windows(date, purpose) if availability_calendar_configured?(purpose)

      window = MERGED_AVAILABILITY[date.wday]
      window ? [window] : []
    end

    # All 30-minute slot start times (Asia/Bangkok) for a date across its windows.
    def generate_slots(date, purpose: nil)
      windows = availability_for(date, purpose: purpose)
      return [] if windows.blank?

      windows.each_with_object([]) do |window, slots|
        start_h, start_m = window[0].split(":").map(&:to_i)
        end_h, end_m = window[1].split(":").map(&:to_i)
        start_time = Time.zone.local(date.year, date.month, date.day, start_h, start_m)
        end_time   = Time.zone.local(date.year, date.month, date.day, end_h, end_m)

        cursor = start_time
        while cursor + DURATION_MINUTES.minutes <= end_time
          slots << cursor
          cursor += DURATION_MINUTES.minutes
        end
      end
    end

    # Slots for a date that are still in the future and not overlapping an active
    # local booking (the backstop; Google already omits taken slot events).
    def available_slots(date, purpose: nil)
      now = Time.current
      candidates = generate_slots(date, purpose: purpose)
      return [] if candidates.blank?

      booked = active.where.not(preferred_at: nil).pluck(:preferred_at)

      candidates.reject do |slot|
        slot <= now || booked.any? { |start| (start.to_time - slot.to_time).abs < DURATION_MINUTES.minutes }
      end
    end

    # Dates within [from..to] (inclusive) that still have at least one bookable
    # slot. Powers the enabled/disabled days on the booking calendar's month grid.
    def available_dates(from:, to:, purpose: nil)
      (from..to).select { |date| available_slots(date, purpose: purpose).any? }
    end

    # The first open slot across the next few days. Used by the inbound phone
    # flow when the caller gave no specific time, or their requested slot was
    # already taken.
    def next_available_slot(from: Date.current, max_days: 14, purpose: nil)
      (0..max_days).each do |offset|
        slot = available_slots(from + offset.days, purpose: purpose).first
        return slot if slot
      end
      nil
    end

    # A list of the next few concrete free slots across upcoming days. Injected
    # into the CALL-E booking prompt so the agent offers real availability —
    # CALL-E has no live data access to query our calendar mid-call, so we
    # snapshot what is open at dispatch time.
    def upcoming_available_slots(purpose: nil, limit: 12, max_days: 14)
      slots = []
      (0..max_days).each do |offset|
        slots.concat(available_slots(Date.current + offset.days, purpose: purpose))
        break if slots.size >= limit
      end
      slots.first(limit)
    end

    # ── 24/7 open availability (callback request form) ─────────────────────
    # Unlike the interview calendar (MERGED_AVAILABILITY), the callback request
    # form is always open: every day and every 30-minute slot of the day. The
    # host then dispatches CALL-E at the chosen (or any) time.

    # All 30-minute slot start times for a date, 00:00 → 23:30 (Asia/Bangkok),
    # excluding any slot that is already in the past.
    def open_slots(date)
      start_time = Time.zone.local(date.year, date.month, date.day, 0, 0)
      end_time   = start_time + 1.day
      now = Time.current

      slots = []
      cursor = start_time
      while cursor + DURATION_MINUTES.minutes <= end_time
        slots << cursor
        cursor += DURATION_MINUTES.minutes
      end
      slots.reject { |slot| slot <= now }
    end

    # Every date within [from..to] that still has at least one future slot. In
    # practice this is every date from today onward (24/7).
    def open_dates(from:, to:)
      (from..to).select { |date| open_slots(date).any? }
    end

    # The CALL-E agent prompt for the INBOUND line (volunteers call our toll-free
    # number). This is configured against the inbound number in the CALL-E
    # dashboard; it is kept here so the booking script is reproducible in code.
    def inbound_call_goal
      <<~TXT.squish
        You are the OpenmindProjects volunteer booking line. When a volunteer
        calls, greet them warmly and help them book a 30-minute appointment.
        Follow these steps in order. Step 1 — collect, one at a time: their full name, their email address so we can send the Google Meet link, their 6-digit contact PIN if they are a returning volunteer (used only to verify their identity), which call they want (onsite/internship interview, online volunteer interview, partnership interview, or a general callback), and a preferred date and time. Do not re-ask for a value the caller has already clearly provided
        unless they correct it. Step 2 — offer slots in Asia/Bangkok time, 30
        minutes long: Tuesday 5:00–8:30 PM (latest start 8:00 PM), Wednesday
        5:15–11:30 PM (latest start 10:45 PM), Thursday 5:00–11:30 PM (latest
        start 11:00 PM — a start at 11:30 PM is invalid because a 30-minute
        appointment would end after the 11:30 PM closing, so offer 11:00 PM
        instead), Friday 5:00–8:00 PM (latest start 7:30 PM). Step 3 — ask if
        they have any questions and record the answer; tell them anything you
        cannot answer will be forwarded to the OpenmindProjects team, without
        estimating when they will reply. Step 4 — read back the full name, email,
        purpose, and the complete date and time in Asia/Bangkok, then ask for
        explicit confirmation. Step 5 — only after the caller confirms, tell them
        they will receive a confirmation email with a Google Meet link, deliver a
        brief closing, return exactly these five structured fields — name, email,
        purpose, preferred_date_time (ISO 8601), and questions — atomically, and
        end the call immediately. Do not continue the conversation.
      TXT
    end

    # Single dispatcher prompt for the ONE inbound number: asks "apply, book, or
    # read your inbox?" and branches. This is what gets pasted into the CALL-E
    # dashboard Goal. The read-inbox branch only collects identity (email + PIN)
    # and promises a call-back — it never reads messages, because the agent has
    # no database access; the webhook triggers the outbound read-back instead.
    def inbound_dispatcher_goal
      <<~TXT.squish
        You are the OpenmindProjects volunteer line. Greet the caller warmly,
        then ask one opening question: "Would you like to submit a volunteer
        application, book (or reschedule) a 30-minute video call appointment, or
        read your inbox message?"

        If they want to submit a volunteer application, help them complete it
        over the phone, one step at a time. Ask one question at a time, validate
        each answer as you go, and re-ask if it is missing or invalid. Never
        re-ask for something already answered unless you need a correction.
        Step 1 — Personal info: first name, family name, email address (check it
        looks like name@example.com), phone number, date of birth (ask for
        year-month-day), and country of residence. If the caller is a returning
        volunteer, also ask for their 6-digit contact PIN to verify their
        identity.
        Step 2 — Preferences: volunteer type (Onsite, Online, or Unpaid
        Internship), travel companion (Solo, Couple or Friend, or Family), and
        volunteer interests (choose from: Building & Repairing/Painting &
        Decorating; Create IT/Programming Course Content; Teach English; Teach
        IT/Programming; Web Development/Design; Social Media (Digital Marketing);
        Fundraising; Photo and Videography). They may pick several.
        Step 3 — Logistics: preferred locations (Thailand, Laos, Cambodia, or
        Nepal), a specific project if they have one, when they plan to start, and
        how long they plan to volunteer (Less than a week, 1 Week, 2 Weeks, 3
        Weeks, 1 Month, 2 Months, 3 Months, 4 Months, 5 Months, 6 Months, or I
        don't know).
        Step 4 — About them: their skills, education and work experience, and why
        they want to volunteer with OpenmindProjects.
        Step 5 — Consent: ask whether they consent to OpenmindProjects storing
        their information so we can respond to their application. Only set
        gdpr_consent to true if they clearly say yes.
        Rules: The applicant must be at least 18 years old; if their date of
        birth makes them younger, politely explain we only accept volunteers aged
        18 or over and end the call without submitting. Keep their volunteering
        availability separate from an interview time. At the end, if they want an
        interview, offer a 30-minute slot in Asia/Bangkok time (Tuesday 5:00-8:30
        PM, Wednesday 5:15-11:30 PM, Thursday 5:00-11:30 PM, Friday 5:00-8:00 PM)
        and record it as preferred_interview_at (ISO 8601). Read back everything
        and ask for confirmation, then return the structured fields and end the
        call.

        If they want to book or reschedule a 30-minute appointment, follow these
        steps in order.
        Step 1 — collect, one at a time: their full name, their email address so
        we can send the Google Meet link, their 6-digit contact PIN if they are a
        returning volunteer (used only to verify their identity), which call they
        want (onsite/internship interview, online volunteer interview,
        partnership interview, or a general callback), and a preferred date and
        time. Do not re-ask for a value the caller has already clearly provided
        unless they correct it.
        Step 2 — offer slots in Asia/Bangkok time, 30 minutes long: Tuesday
        5:00–8:30 PM (latest start 8:00 PM), Wednesday 5:15–11:30 PM (latest
        start 10:45 PM), Thursday 5:00–11:30 PM (latest start 11:00 PM), Friday
        5:00–8:00 PM (latest start 7:30 PM).
        Step 3 — ask if they have any questions and record the answer; tell them
        anything you cannot answer will be forwarded to the OpenmindProjects team.
        Step 4 — read back the full name, email, purpose, and the complete date
        and time in Asia/Bangkok, then ask for explicit confirmation.
        Step 5 — only after the caller confirms, tell them they will receive a
        confirmation email with a Google Meet link, deliver a brief closing,
        return the structured fields, and end the call immediately.

        If they want to read their inbox message, do not attempt to read any
        messages yourself — you cannot access their inbox. Instead, collect their
        email address and their 6-digit contact PIN (used only to verify their
        identity), then tell them you will call them right back to read their
        messages. Set read_inbox to true and return the email and contact_pin
        fields, then end the call.

        Whichever path they choose, return only the structured fields for that
        path, atomically, and end the call immediately. Do not continue the
        conversation.
      TXT
    end

    private

    # Windows parsed from the type's Google calendar slot events for one date.
    # Each event is a window the host maintains (recurring events expanded into
    # daily occurrences); we return [start, end] "HH:MM" in Bangkok time.
    def google_availability_windows(date, purpose)
      calendar_id = calendar_id_for(purpose)
      return [] if calendar_id.blank?

      time_min = Time.zone.local(date.year, date.month, date.day, 0, 0).to_datetime
      time_max = time_min + 1

      GoogleCalendarService.new
        .list_events(calendar_id: calendar_id, time_min: time_min, time_max: time_max)
        .filter_map do |event|
          start_at = event[:start]
          end_at = event[:end]
          next if start_at.blank? || end_at.blank?

          [start_at.in_time_zone.strftime("%H:%M"), end_at.in_time_zone.strftime("%H:%M")]
        end
    end
  end

  # Natural-language task for the post-booking reminder call. Its job is to
  # confirm the volunteer received the appointment email, answer their remaining
  # questions, and flag a missed email for host escalation.
  def follow_up_call_goal
    "#{COMPANY_CONTEXT} You are calling #{name} to follow up on their scheduled " \
    "#{purpose.titleize} appointment #{preferred_at_text}. Open by greeting them " \
    "by name and confirming you are calling about their appointment " \
    "(#{booking_number}). Ask whether they received the confirmation email with " \
    "the Google Meet link. If they did not receive it, apologize, confirm their " \
    "email address, and reassure them that our team will resend the meeting " \
    "details right away. Then ask if they have any questions about the meeting " \
    "or the appointment, and answer as clearly as you can. End by summarizing " \
    "and thanking them. #{voice_profile} #{conversation_guidelines} " \
    "In your summary record whether they received the email (received_email: " \
    "yes or no), their email address, and any questions or issues they raised."
  end

  # Human-readable appointment time for emails and the reminder call script.
  def preferred_at_text
    return "not yet scheduled" if preferred_at.blank?

    I18n.l(preferred_at, format: :short)
  end

  def terminal?
    %w[completed failed].include?(status)
  end

  # Coarse meeting state for the Meeting Schedule dashboard. The three buckets
  # are mutually exclusive so a booking lands in exactly one tab:
  #
  #   * "urgent"    — the follow-up call reported a missed email, or the meeting
  #                   is happening today (hosts must act now).
  #   * "completed" — the slot has passed or the booking was released.
  #   * "incoming"  — everything else (future, non-urgent, still needs a slot).
  def meeting_state
    return "urgent" if escalation_needed?
    return "completed" if RELEASED_STATUSES.include?(status)
    return "completed" if preferred_at.present? && preferred_at.past?

    if preferred_at.present? && preferred_at.to_date == Date.current && preferred_at.future?
      return "urgent"
    end

    "incoming"
  end

  # True when the meeting needs immediate host attention (today's meeting or a
  # missed-email escalation). Used to set the staff task priority and to sort
  # the "Urgent" tab ahead of the rest.
  def urgent?
    meeting_state == "urgent"
  end

  # Auto-generate a staff HostTask so the host team sees every confirmed meeting
  # (with its Meet link) in the Tasks queue. Idempotent by call_booking_id and
  # best-effort: a missing host organization is logged, never raised.
  def create_host_task!
    return if HostTask.exists?(call_booking_id: id)

    org = openmindprojects_org
    creator = org&.user
    if org.blank? || creator.blank?
      Rails.logger.warn "[CallBooking] host task not created for booking #{id} — OpenmindProjects organization not found."
      return nil
    end

    HostTask.create!(
      organization_profile: org,
      creator_user: creator,
      call_booking: self,
      volunteer_application: volunteer_application,
      title: "Meeting: #{name} — #{purpose.titleize} (#{booking_number})",
      description: meeting_task_description,
      priority: urgent? ? "urgent" : "normal",
      category: "meeting",
      status: "pending",
      due_date: (preferred_at || Time.current).to_date
    )
  rescue StandardError => e
    Rails.logger.error "[CallBooking] host task creation failed for booking #{id}: #{e.class} #{e.message}"
    nil
  end

  # Reflect a confirmed interview booking back onto the linked VolunteerApplication
  # so the host volunteer detail page shows the interview and its Join Meeting
  # link. No-op for public "book a call" bookings (which have no application).
  def sync_to_volunteer_application!
    app = volunteer_application
    return if app.blank?

    attrs = {}
    attrs[:interview_scheduled_at] = preferred_at if preferred_at.present?
    attrs[:meeting_url] = meet_link if meet_link.present?
    app.update!(attrs) if attrs.any?
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error "[CallBooking] volunteer application sync failed for booking #{id}: #{e.message}"
  end

  # Persist the outcome of a finished CALL-E call run.
  def apply_terminal_result!(result)
    # A dry-run "COMPLETED" is a simulation (no real call placed). Never persist
    # its fabricated status/summary/transcript into a real booking, and never let
    # it trigger follow-up side effects (Meet attendee changes, missed-email
    # escalation). Mirrors CallbackRequest#apply_terminal_result!.
    if result.dry_run?
      Rails.logger.info "[CallBooking] dry-run result for booking #{id} (run_id=#{result.run_id}) — not persisting simulated outcome"
      return
    end

    self.call_status = result.status
    self.callee_number = result.callee_number if result.callee_number.present?
    self.summary = result.summary.presence
    self.transcript = result.transcript.presence
    self.duration_seconds = result.duration_seconds if result.duration_seconds.present?

    if result.structured_result.present?
      self.structured_result = result.structured_result
      captured_email = result.structured_result["email"] if result.structured_result.respond_to?(:[])
      self.email = captured_email if captured_email.present? && email.blank?
    end

    # Keep the granular CALL-E outcome in +call_status+; collapse the lifecycle
    # to completed vs failed. A completed conversation is the only success case.
    self.status = result.status.to_s.upcase == "COMPLETED" ? "completed" : "failed"
    save!
  end

  # Create a replacement booking at a new time and link back to this one. Marks
  # this booking "rescheduled", cancels its Google Calendar event, and re-runs the
  # full appointment flow (calendar + Meet + email + reminder call) for the new slot.
  def reschedule!(new_preferred_at)
    return nil if terminal? || status == "rescheduled"

    new_booking = CallBooking.create!(
      name: name,
      phone: phone,
      email: email,
      purpose: purpose,
      preferred_at: new_preferred_at,
      rescheduled_from_id: id
    )

    update!(status: "rescheduled")
    cancel_calendar_event!

    BookAppointmentJob.perform_later(new_booking.id)

    new_booking
  end

  # Remove the linked Google Calendar event (used on cancel/reschedule).
  def cancel_calendar_event!
    return if google_event_id.blank?

    GoogleCalendarService.new.cancel_event(google_event_id, calendar_id: CallBooking.calendar_id_for(purpose))
    update!(google_event_id: nil, meet_link: nil, calendar_link: nil)
  end

  # True when the follow-up call reported the volunteer did not receive their
  # appointment email, so a host must resend it.
  def escalation_needed?
    return false unless structured_result.is_a?(Hash)

    %w[no false n not_received did_not_receive].include?(
      structured_result["received_email"].to_s.downcase.strip
    )
  end

  # Escalate a missed appointment email by creating an urgent host task (with a
  # ready-to-send draft containing the meeting URL) for the OpenmindProjects
  # team. Best-effort: never raises, so the reminder job always finishes.
  def escalate_missed_email!
    org = openmindprojects_org
    creator = org&.user
    return if org.blank? || creator.blank?

    HostTask.create!(
      organization_profile: org,
      creator_user: creator,
      title: "[Mindy] Resend appointment email — #{booking_number}",
      description: resend_email_draft,
      priority: "urgent",
      category: "communication",
      status: "pending",
      due_date: Date.current
    )
  rescue StandardError => e
    Rails.logger.error "[CallBooking] Mindy escalation failed: #{e.class} #{e.message}"
  end

  private

  # Resolve the owning host organization at creation time so the Meeting
  # Schedule dashboard can scope by org even for public web bookings that have
  # no VolunteerApplication. No-op when already set (e.g. by the CALL-E flow).
  def ensure_organization_profile
    self.organization_profile_id ||= openmindprojects_org&.id
  end

  # Human-readable meeting summary for the auto-generated staff task.
  def meeting_task_description
    [
      "Booking: #{booking_number}",
      "When: #{preferred_at_text} (Asia/Bangkok)",
      "Purpose: #{purpose.titleize}",
      meet_link.present? ? "Meet: #{meet_link}" : "Meet link: pending — calendar event may have failed"
    ].compact.join("\n")
  end

  # Reject a slot that overlaps an existing active booking. Appointments are
  # 30 minutes long, so two bookings conflict when their start times are less
  # than 30 minutes apart. This catches off-grid times the CALL-E agent may
  # return (e.g. 18:45) that a pure exact-match check would miss.
  def preferred_at_available
    return if preferred_at.blank?

    overlap = CallBooking.active
                         .where.not(id: id)
                         .where("preferred_at > ? AND preferred_at < ?",
                                preferred_at - DURATION_MINUTES.minutes,
                                preferred_at + DURATION_MINUTES.minutes)
                         .exists?

    if overlap
      errors.add(:preferred_at, "is no longer available. Please choose another slot.")
    end
  end

  # The OpenmindProjects host organization that owns the urgent escalation task.
  def openmindprojects_org
    OrganizationProfile
      .where("org_name ILIKE ? OR contact_email ILIKE ?", "%openmind%", "%hello@openmindprojects.net%")
      .first
  end

  # A ready-to-send draft for the host team, with the meeting schedule URL.
  def resend_email_draft
    link = meet_link.presence || calendar_link.presence || status_url
    base = <<~TXT
      Hi #{name},

      Sorry you didn't receive your appointment details — here they are again:

      Appointment: #{purpose.titleize} (#{booking_number})
      When: #{preferred_at_text} (Asia/Bangkok)
      Join: #{link}

      If you have any questions, just reply to this email.

      — The OpenmindProjects Team
    TXT

    mindy_draft(base).presence || base
  end

  # Best-effort polish via Mindy's Ops Autopilot; returns nil when unavailable.
  def mindy_draft(base)
    MindyClient.ops_autopilot(
      action: "draft_followup",
      context: {
        volunteer_name: name,
        purpose: purpose,
        booking_number: booking_number,
        meeting_url: meet_link.presence || status_url,
        raw: base
      }
    ).to_s.strip
  rescue StandardError => e
    Rails.logger.warn "[CallBooking] Mindy draft unavailable: #{e.message}"
    nil
  end

  def status_url
    Rails.application.routes.url_helpers.call_booking_url(token: token, host: app_host, protocol: "https")
  end

  def app_host
    ENV["APP_HOST"].presence || "call-e.openmindprojects.org"
  end

  # Human-readable reference (e.g. OMP-000123) that volunteers quote back to the
  # AI when rescheduling. Derived from the DB id so it stays unique and short.
  def assign_booking_number
    update_column(:booking_number, format("OMP-%06d", id))
  end

  # Public status page is keyed by an unguessable token (not the numeric id)
  # so a volunteer's phone number is never exposed through sequential URLs.
  def set_token
    self.token ||= SecureRandom.urlsafe_base64(24)
  end

  # Best-effort normalization to E.164 so the public form tolerates common
  # domestic formats. Leading-zero numbers are assumed to be Thai (+66).
  def normalize_phone
    return if phone.blank?

    digits = phone.to_s.gsub(/[^\d+]/, "")
    self.phone =
      if digits.start_with?("+")
        digits
      elsif digits.start_with?("0")
        "+66#{digits[1..]}"
      else
        "+#{digits}"
      end
  end
end
