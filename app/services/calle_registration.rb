# CALL-E "registration" assistant: the voice equivalent of the 5-step volunteer
# application form (app/views/applications/new.html.erb).
#
# This service owns the three responsibilities that make a phone-collected
# application safe and consistent with the web form:
#
#   1. call_goal — the natural-language script that guides a volunteer through
#      every form step, validating each answer in real time (email format,
#      phone number, age >= 18, required fields, and verbal GDPR consent).
#   2. application_attributes — defensive normalization of the CALL-E structured
#      result into VolunteerApplication attributes (E.164 phone, canonical
#      option values, comma-separated multi-selects, ISO dates).
#   3. submit! — server-side validation + persistence, producing a
#      VolunteerApplication and, when an interview slot was captured, a linked
#      CallBooking so the voice path and the web form share one pipeline.
#
# All input is treated as untrusted: nothing is persisted unless it passes the
# same model validations the web form uses.
class CalleRegistration
  Result = Struct.new(:application, :booking, :errors, keyword_init: true) do
    def persisted?
      application&.persisted?
    end
  end

  # ── Voice script ──────────────────────────────────────────────────────────

  # The full registration goal. Kept in one place so the script is reproducible
  # in code and can be pasted into the CALL-E dashboard for the inbound line.
  def self.call_goal(name: nil, email: nil)
    personalization = +""
    personalization << " You are calling #{name} back as requested." if name.present?
    personalization << " You already have their email as #{email}, so confirm it rather than asking from scratch." if email.present?

    <<~TXT.squish
      You are the OpenmindProjects volunteer application assistant.#{personalization}
      Keep the call short — aim to finish within 5 minutes. Ask one question at
      a time, wait for the answer, and never re-ask anything already answered.
      Give short, single-sentence replies with no filler or small talk.

      Collect only these five things, in order: their first name and family
      name; their email address (confirm the spelling once); why they want to
      volunteer with OpenmindProjects; their skills and background (education,
      work experience, or other relevant skills); and whether they consent to us
      storing their information so we can respond to their application (record
      gdpr_consent as true only if they clearly say yes).

      When you confirm a spelling — an email address or any English word — read
      each letter using the NATO phonetic alphabet, the way airline and call
      center agents do, so letters cannot be confused. For example, for B5J2TX
      say: "Bravo, five, Juliet, two, Tango, X-ray." Use this list: A Alpha, B
      Bravo, C Charlie, D Delta, E Echo, F Foxtrot, G Golf, H Hotel, I India, J
      Juliet, K Kilo, L Lima, M Mike, N November, O Oscar, P Papa, Q Quebec, R
      Romeo, S Sierra, T Tango, U Uniform, V Victor, W Whiskey, X X-ray, Y
      Yankee, Z Zulu.

      If they say it is not a good time to talk right now, ask what day and time
      works best for us to call them back, record it as preferred_callback_at
      (ISO 8601), tell them we will call back then, and end the call without
      collecting the rest.

      Do not ask for their date of birth, country, phone number, volunteer type,
      availability, or anything else. Once you have the answers, thank them and
      explain what happens next: our support agent will use the information they
      provided to help submit their application form; the OpenmindProjects team
      will get back to them with a matching project and arrange a live video
      interview and Q&A; they will receive an email notification; and they can
      view their submitted application in the Volunteer Portal dashboard. If
      this is their first time, their account will be created automatically and
      an email with access details will be sent to their email address. If they
      have any problems, tell them to contact us by email or call our hotline
      +1 877-757-4423. Then end the call.
    TXT
  end

  # ── Parsing ───────────────────────────────────────────────────────────────

  # True when a completed CALL-E payload is a full registration call rather than
  # a simple booking call. Detected by registration-specific structured fields.
  def self.registration_call?(source)
    result = source.respond_to?(:structured_result) ? source.structured_result : source
    return false unless result.is_a?(Hash)

    (result["first_name"].present? || result["last_name"].present?) &&
      (result["motivation"].present? || result["volunteer_type"].present?)
  end

  # Map a CALL-E structured result to VolunteerApplication attributes. Values
  # are normalized but NOT validated here — validation happens in #submit!.
  def self.application_attributes(structured_result)
    result = structured_result.is_a?(Hash) ? structured_result : {}

    {
      first_name: result["first_name"].to_s.strip.presence,
      last_name: result["last_name"].to_s.strip.presence,
      email: normalize_email(result["email"]),
      whatsapp_phone: normalize_phone(result["phone"]),
      phone: normalize_phone(result["phone"]),
      date_of_birth: parse_date(result["date_of_birth"]),
      country: result["country"].to_s.strip.presence,
      nationality: result["country"].to_s.strip.presence,
      volunteer_type: normalize_volunteer_type(result["volunteer_type"]),
      application_type: normalize_volunteer_type(result["volunteer_type"]),
      travel_companion: normalize_free_text(result["travel_companion"]),
      volunteer_work: normalize_multi(result["volunteer_work"], VolunteerApplication::VOLUNTEER_WORK_OPTIONS),
      other_volunteer_work: result["other_volunteer_work"].to_s.strip.presence,
      preferred_locations: normalize_multi(result["preferred_locations"], VolunteerApplication::LOCATION_OPTIONS),
      preferred_start_date: parse_date(result["preferred_start_date"]),
      planned_duration: normalize_free_text(result["planned_duration"]),
      skills_education: result["skills_education"].to_s.strip.presence,
      skills: result["skills_education"].to_s.strip.presence,
      motivation: result["motivation"].to_s.strip.presence,
      comments: result["comments"].to_s.strip.presence,
      gdpr_consent: truthy?(result["gdpr_consent"]),
      source_url: "calle_registration"
    }
  end

  # Whether the applicant meets the >= 18 age requirement (parity with the CSV
  # importer's eligibility screening). Missing DOB is not a hard fail here —
  # the model still requires the other fields, and DOB is optional in the schema.
  def self.eligible?(date_of_birth)
    return true if date_of_birth.blank?

    date_of_birth <= 18.years.ago.to_date
  end

  # ── Persistence ───────────────────────────────────────────────────────────

  # Validate and persist a phone-collected application (plus an optional linked
  # interview CallBooking). Never raises — inspect the returned Result.
  #
  #   run_id            — CALL-E call id, used for idempotency.
  #   phone             — the authoritative E.164 number (caller for inbound,
  #                       callee for outbound), used when the result omits it.
  #   structured_result — the CALL-E structured outcome.
  #   summary/transcript — stored on the application's meta for audit.
  def self.submit!(run_id:, phone:, structured_result:, summary: nil, transcript: nil)
    if run_id.present? && (existing = VolunteerApplication.find_by(calle_run_id: run_id))
      return Result.new(application: existing, booking: existing.call_bookings.first, errors: [])
    end

    attrs = application_attributes(structured_result)
    attrs[:whatsapp_phone] ||= normalize_phone(phone)
    attrs[:phone] ||= normalize_phone(phone)

    application = VolunteerApplication.new(attrs)
    application.calle_run_id = run_id.presence
    application.pipeline_stage = "new" if application.respond_to?(:pipeline_stage=)
    application.status = "pending" if application.respond_to?(:status=)

    # Bypass host-org/project scoping: phone-collected applications aren't tied
    # to a specific project, so they default to the OpenmindProjects Foundation
    # and stay "open" (project_id = nil) until a human matches them later.
    application.organization_profile_id ||= default_organization_id

    application.meta = (application.meta || {}).merge(
      "calle" => { "summary" => summary.to_s.presence, "transcript" => transcript.to_s.presence }.compact
    )

    unless eligible?(application.date_of_birth)
      application.errors.add(:date_of_birth, "applicant must be 18 or older")
      return Result.new(application: application, booking: nil, errors: application.errors.full_messages)
    end

    application.save!(context: :public_application)

    # Ensure the per-person contact PIN exists for phone-collected applications
    # too, so the voice path and web form share the same identity key.
    application.contact_pin

    # Auto-create (or link) the volunteer's account so they can view their
    # submitted application in the Volunteer Portal dashboard.
    user = ensure_volunteer_account(application)

    # Auto-create a BookingRequest so the application shows up in the host
    # Volunteer pipeline (/host/volunteers), which joins on booking_requests.
    ensure_booking_request(application, user)

    booking = nil
    preferred_at = parse_time(structured_result.is_a?(Hash) ? structured_result["preferred_interview_at"] : nil)
    booking = create_booking(application, phone, preferred_at, run_id, summary, transcript) if preferred_at.present?

    notify(application)

    Result.new(application: application, booking: booking, errors: [])
  rescue ActiveRecord::RecordInvalid => e
    Result.new(application: e.record, booking: nil, errors: e.record.errors.full_messages)
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  def self.create_booking(application, phone, preferred_at, run_id, summary, transcript)
    booking = CallBooking.create!(
      name: application.full_name,
      phone: normalize_phone(phone).presence || application.whatsapp_phone,
      email: application.email,
      purpose: purpose_from_type(application.volunteer_type),
      preferred_at: preferred_at,
      run_id: run_id.presence,
      summary: summary.presence,
      transcript: transcript.presence,
      volunteer_application_id: application.id
    )

    # Reuse the standard appointment pipeline (calendar + Meet + email); skip
    # the reminder call since the volunteer just finished this conversation.
    BookAppointmentJob.perform_later(booking.id, false)
    booking
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error "[CalleRegistration] interview booking failed: #{e.record.errors.full_messages.join('; ')}"
    nil
  end

  def self.notify(application)
    VolunteerMailer.application_received(application).deliver_later
    VolunteerMailer.admin_notification(application).deliver_later

    if application.respond_to?(:volunteer_notes) && (VolunteerNote.table_exists? rescue false)
      application.volunteer_notes.create!(
        note_type: "system",
        body: "Application submitted via CALL-E phone registration"
      )
    end
  rescue StandardError => e
    Rails.logger.error "[CalleRegistration] notify failed: #{e.class} #{e.message}"
  end

  # Default host organization for phone-collected applications — the
  # OpenmindProjects Foundation. CALL-E registrations are not tied to a project,
  # so they are owned by the foundation and stay "open" (project_id = nil) until
  # a human matches them. Mirrors the lookup used by CallbackRequest/CallBooking.
  def self.default_organization_id
    OrganizationProfile.find_by(org_name: "OpenmindProjects Foundation")&.id ||
      OrganizationProfile
        .where("org_name ILIKE ? OR contact_email ILIKE ?", "%openmind%", "%hello@openmindprojects.net%")
        .order(:id)
        .first&.id
  end

  # Default project for phone-collected applications — the Foundation's first
  # active project. BookingRequest requires a concrete project (the
  # /host/volunteers pipeline joins booking_requests.project_id), so the lead is
  # attached to this catch-all project while the application itself stays "open"
  # (project_id = nil) until a human matches it to a real project.
  def self.default_project_id(organization_id)
    return nil if organization_id.blank?
    Project.where(organization_profile_id: organization_id).active.ordered.pick(:id)
  end

  # Auto-create a BookingRequest so a phone-collected application is visible in
  # the host Volunteer pipeline (/host/volunteers). Uses flexible dates (no
  # start/end required) and links the volunteer's auto-created account.
  # Best-effort: a missing default project must never fail the application.
  def self.ensure_booking_request(application, user)
    project_id = application.project_id || default_project_id(application.organization_profile_id)
    return nil if project_id.blank?

    BookingRequest.create!(
      volunteer_application: application,
      project_id: project_id,
      user_id: user&.id,
      is_flexible_dates: true,
      preferred_duration: "Flexible",
      status: "pending",
      payment_status: "unpaid"
    )
  rescue StandardError => e
    Rails.logger.error "[CalleRegistration] booking request creation failed for #{application.email}: #{e.class} #{e.message}"
    nil
  end

  # Auto-create (or link) a volunteer User account for a phone-collected
  # application, matching the web booking flow. Best-effort: a failure here must
  # never invalidate an already-persisted application.
  def self.ensure_volunteer_account(application)
    User.find_or_create_volunteer!(
      email: application.email,
      first_name: application.first_name,
      last_name: application.last_name
    )
  rescue StandardError => e
    Rails.logger.error "[CalleRegistration] volunteer account creation failed for #{application.email}: #{e.class} #{e.message}"
    nil
  end

  def self.purpose_from_type(volunteer_type)
    case volunteer_type.to_s.downcase
    when "online" then "volunteering_info"
    else "volunteer"
    end
  end

  def self.normalize_email(value)
    value.to_s.strip.downcase.presence
  end

  # Best-effort E.164 normalization (mirrors CallBooking#normalize_phone).
  def self.normalize_phone(value)
    digits = value.to_s.gsub(/[^\d+]/, "")
    return nil if digits.blank?

    if digits.start_with?("+")
      digits
    elsif digits.start_with?("0")
      "+66#{digits[1..]}"
    else
      "+#{digits}"
    end
  end

  def self.normalize_volunteer_type(value)
    v = value.to_s.strip
    return nil if v.blank?

    d = v.downcase
    return "Unpaid Internship" if d.include?("intern")
    return "Online" if d.include?("online") || d.include?("remote")
    return "Onsite" if d.include?("onsite") || d.include?("on-site") || d.include?("in person")

    VolunteerApplication::VOLUNTEER_TYPES.include?(v) ? v : nil
  end

  def self.normalize_free_text(value)
    value.to_s.strip.presence
  end

  # Split a free-text multi-select and keep only canonical option values.
  def self.normalize_multi(value, options)
    list = value.is_a?(Array) ? value : value.to_s.split(/[,\n;]/)
    list.map(&:strip).compact_blank.filter_map { |item| options.find { |o| o.casecmp?(item) } }.uniq
  end

  def self.parse_date(value)
    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def self.parse_time(value)
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def self.truthy?(value)
    case value
    when true, "true", "yes", "1", 1 then true
    when false, "false", "no", "0", 0 then false
    else value.present?
    end
  end
end
