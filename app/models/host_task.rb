class HostTask < ApplicationRecord
  include CalleVoice

  PRIORITIES = %w[low normal high urgent].freeze
  STATUSES   = %w[pending in_progress completed].freeze
  CATEGORIES = %w[general onboarding logistics interview meeting communication verification feedback_review].freeze

  belongs_to :organization_profile
  belongs_to :creator_user,          class_name: "User"
  belongs_to :volunteer_application, optional: true
  belongs_to :booking_request,       optional: true
  belongs_to :callback_request,      optional: true
  belongs_to :call_booking,          optional: true
  belongs_to :project,               optional: true
  belongs_to :dispatched_by,         class_name: "User", optional: true
  belongs_to :mission_goal_progress, optional: true

  has_many :host_task_assignments, dependent: :destroy
  has_many :assigned_users, through: :host_task_assignments, source: :user

  accepts_nested_attributes_for :host_task_assignments, allow_destroy: true, reject_if: :all_blank

  validates :title,    presence: true, length: { maximum: 255 }
  validates :priority, inclusion: { in: PRIORITIES }
  validates :status,   inclusion: { in: STATUSES }
  validates :category, inclusion: { in: CATEGORIES }

  # Scopes
  scope :pending,       -> { where(status: "pending") }
  scope :in_progress,   -> { where(status: "in_progress") }
  scope :incomplete,    -> { where(status: %w[pending in_progress]) }
  scope :completed,     -> { where(status: "completed") }
  scope :due_today,     -> { where(due_date: Date.current) }
  scope :overdue,       -> { incomplete.where("due_date < ?", Date.current) }
  scope :by_priority,   ->(p) { where(priority: p) if p.present? }
  scope :by_category,   ->(c) { where(category: c) if c.present? }
  scope :for_user,      ->(u_id) { joins(:host_task_assignments).where(host_task_assignments: { user_id: u_id }) }
  scope :for_volunteer, ->(app_id) { where(volunteer_application_id: app_id) if app_id.present? }
  scope :recent,        -> { order(created_at: :desc) }
  scope :by_due_date,   -> { order(Arel.sql("due_date IS NULL, due_date ASC")) }
  # Tasks the CALL-E voice agent handles: explicitly assigned to CALL-E, linked
  # to a callback request (bookcall/registration/read-inbox), or linked to a
  # mission goal (onboarding / feedback review voice calls).
  scope :call_e_agent, -> {
    where("calle_agent = ? OR callback_request_id IS NOT NULL OR mission_goal_progress_id IS NOT NULL", true)
  }

  # Callbacks
  after_update :set_completed_at, if: -> { saved_change_to_status? && status == "completed" }
  after_update :verify_linked_mission_goal,
               if: -> { saved_change_to_status? && status == "completed" && category == "verification" }
  after_update :complete_linked_mission_goal,
               if: -> { saved_change_to_status? && status == "completed" && mission_goal_progress_id.present? }
  after_commit :broadcast_google_chat_alert, on: [ :create ]
  after_commit :sync_google_tasks, on: [ :create, :update ]

  # Helpers
  def overdue?
    due_date.present? && due_date < Date.current && status != "completed"
  end

  def assignees_display
    names = []
    names << "CALL-E (AI)" if calle_agent?
    names.concat(host_task_assignments.map(&:assignee_name).compact_blank)
    names.any? ? names.join(", ") : "Unassigned"
  end

  def priority_color
    case priority
    when "urgent" then "#EF4444"
    when "high"   then "#F59E0B"
    when "normal" then "#3B82F6"
    when "low"    then "#6B7280"
    else "#6B7280"
    end
  end

  def status_color
    status == "completed" ? "#10B981" : "#3B82F6"
  end

  def category_icon
    case category
    when "general"       then "ph-clipboard-text"
    when "onboarding"    then "ph-rocket-launch"
    when "logistics"     then "ph-truck"
    when "interview"     then "ph-video-camera"
    when "meeting"       then "ph-calendar-check"
    when "communication" then "ph-chat-circle"
    when "verification"  then "ph-seal-check"
    when "feedback_review" then "ph-star"
    else "ph-check-square"
    end
  end

  def toggle_status_label
    status == "completed" ? "Reopen" : "Complete"
  end

  def toggle_status_icon
    status == "completed" ? "ph-arrow-counter-clockwise" : "ph-check-circle"
  end

  def status_label
    status == "completed" ? "Closed" : "Open"
  end

  def dispatched?
    dispatched_at.present?
  end

  def mark_dispatched!(user)
    update!(dispatched_at: Time.current, dispatched_by: user)
  end

  def uploads_enabled?
    ActiveModel::Type::Boolean.new.cast(uploads_enabled)
  end

  def submission_count
    host_task_assignments.sum { |a| a.submission_files.count }
  end

  def ensure_volunteer_user_assigned!
    return unless volunteer_application

    volunteer_user = volunteer_application.booking_requests
      .where.not(user_id: nil)
      .order(created_at: :desc)
      .first&.user
    return unless volunteer_user
    return if host_task_assignments.exists?(user_id: volunteer_user.id)

    host_task_assignments.create!(user: volunteer_user)
  end

  # The volunteer this task is about, resolved from the linked application or
  # booking. Used by the voice-goal prompt so CALL-E can greet them by name.
  def volunteer_name
    volunteer_application&.full_name || booking_request&.volunteer_name || "the volunteer"
  end

  # Best-effort E.164 phone number for the volunteer, resolved from the
  # application (phone / whatsapp) then the linked user's volunteer profile.
  # Returns nil when no usable number exists (the task then can't be dispatched).
  def volunteer_phone
    app = volunteer_application || booking_request&.volunteer_application
    user = app&.booking_requests&.where.not(user_id: nil)&.order(created_at: :desc)&.first&.user
    user ||= booking_request&.user

    candidates = []
    candidates << app&.phone
    candidates << app&.whatsapp_phone
    if user&.volunteer_profile
      candidates << user.volunteer_profile.phone
      candidates << user.volunteer_profile.mobile
    end

    candidates.compact_blank.each do |raw|
      normalized = CalleRegistration.normalize_phone(raw)
      return normalized if normalized.present?
    end
    nil
  end

  # True when a host can approve and dispatch CALL-E to place an outbound call
  # to the volunteer: the task is linked to a mission goal, has a phone number,
  # is still open, and hasn't already been dispatched.
  def voice_dispatchable?
    mission_goal_progress_id.present? && volunteer_phone.present? &&
      status != "completed" && !dispatched?
  end

  # True when the host must take an explicit action before the task can move
  # forward — approve & call, approve & send, or review & verify. Mirrors the
  # action buttons rendered on the task card, so the CALL-E Agent dashboard can
  # surface an accurate "needs attention" queue.
  def needs_attention?
    return false if status == "completed"
    return true if category == "verification"
    return true if voice_dispatchable?
    return true if callback_request.present? && !dispatched?
    return true if category == "communication" && description.present? && !dispatched? && callback_request.blank?

    false
  end

  # Short label for the pending host action, or nil when nothing is required.
  def action_required_label
    return nil unless needs_attention?
    return "Approve & call" if voice_dispatchable? || callback_request.present?
    return "Review & verify" if category == "verification"
    return "Approve & send" if category == "communication"

    "Action needed"
  end

  # The natural-language CALL-E goal for the outbound voice call. The draft
  # description (Mindy's script) is the substance; the shared voice building
  # blocks wrap it so the call opens, flows, and closes like every other call.
  def voice_goal
    [
      COMPANY_CONTEXT,
      "You are calling #{volunteer_name} on behalf of OpenmindProjects.",
      "Open the call by greeting #{volunteer_name} by name and confirming you are calling from OpenmindProjects.",
      description.presence,
      voice_profile,
      conversation_guidelines,
      "Before ending, briefly summarize what you captured and tell them what happens next, then thank them warmly."
    ].compact.join(" ")
  end

  # Applies a terminal CALL-E outcome to this goal-linked voice task. A
  # completed (non-dry-run) call closes the task, which triggers the mission
  # goal verification; any other outcome reopens it so the host can retry.
  def apply_voice_result!(result)
    if result.dry_run?
      Rails.logger.info "[HostTask] dry-run voice result for task #{id} (run_id=#{result.run_id}) — not persisting simulated outcome"
      return
    end

    if result.status.to_s.upcase == "COMPLETED"
      update!(status: "completed")
    else
      reopen_voice_dispatch!
    end
  end

  # Reopen a goal-linked voice task after a non-completed call (no answer,
  # voicemail, busy, error) so the "Approve & call" button reappears.
  def reopen_voice_dispatch!
    update!(status: "pending", dispatched_at: nil, dispatched_by_id: nil)
  end

  private

  def verify_linked_mission_goal
    progress = MissionGoalProgress
      .where("evidence->>'host_task_id' = ?", id.to_s)
      .first
    return unless progress

    MissionEngineService.verify_goal!(progress, verified_by: dispatched_by)
  rescue StandardError => e
    Rails.logger.error "[HostTask] Could not verify linked mission goal: #{e.class} #{e.message}"
  end

  # When a goal-linked voice task (onboarding/feedback review) is completed,
  # verify the volunteer's mission goal so the gamified progression advances.
  def complete_linked_mission_goal
    MissionEngineService.verify_goal!(mission_goal_progress, verified_by: dispatched_by)
  rescue StandardError => e
    Rails.logger.error "[HostTask] Could not complete linked mission goal: #{e.class} #{e.message}"
  end

  def set_completed_at
    update_column(:completed_at, Time.current)
  end

  def broadcast_google_chat_alert
    return unless organization_profile&.google_chat_enabled?
    GoogleChatService.new(organization_profile).send_task_assigned_notification(self)
  rescue => e
    Rails.logger.error "[GoogleChatAlert] Error broadcasting task alert: #{e.message}"
  end

  def sync_google_tasks
    return unless organization_profile&.google_tasks_enabled?
    GoogleTasksService.sync_task(self)
  rescue => e
    Rails.logger.error "[GoogleTasksSync] Error syncing task to Google Tasks: #{e.message}"
  end
end
