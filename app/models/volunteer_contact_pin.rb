# A per-person, six-digit contact PIN used to verify a volunteer's identity over
# the CALL-E hotline and other self-service flows (check application status,
# book/reschedule a call, access their inbox).
#
# One PIN per person, keyed by canonical (trimmed + lowercased) email address —
# never per application — so every application submitted with the same email
# resolves to the same PIN.
#
# Security properties:
#   * Generated with SecureRandom (a CSPRNG), never `rand`/`Time`-based values,
#     so PINs are unpredictable and uniformly distributed across 000000–999999.
#   * +pin+ is reversible-encrypted at rest via ActiveRecord::Encryption, so we
#     can show/email it back to the volunteer but never store plaintext.
#   * +pin_digest+ is an HMAC-SHA256 (keyed pepper) of the PIN, used for O(1)
#     constant-time verification and to enforce global uniqueness via a unique
#     index — with a collision retry loop on top.
class VolunteerContactPin < ApplicationRecord
  encrypts :pin

  PIN_LENGTH = 6
  MAX_COLLISION_ATTEMPTS = 10

  # Brute-force protection for hotline/API authentication: lock an identity after
  # this many consecutive failures, with exponential backoff on repeat lockouts.
  MAX_FAILED_ATTEMPTS = 5
  BASE_LOCKOUT = 15.minutes

  before_validation :normalize_email

  validates :email_canonical, presence: true, uniqueness: true,
                              format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :pin, presence: true, format: { with: /\A\d{6}\z/ }
  validates :pin_digest, presence: true, uniqueness: true

  # ── Class API ──────────────────────────────────────────────────────────────

  # Return the existing PIN record for +email+, creating one (with a fresh,
  # collision-free PIN) on first use. Returns nil for a blank/invalid email.
  def self.for_email(email)
    canonical = canonicalize(email)
    return nil if canonical.blank?

    existing = find_by(email_canonical: canonical)
    return existing if existing

    create_for_email!(canonical)
  end

  # True when +email+ exists and +candidate+ matches its stored PIN, and the
  # identity is not currently locked out. Used as the authentication gate for
  # hotline/self-service actions. Records failures and applies a progressive
  # lockout (see MAX_FAILED_ATTEMPTS / BASE_LOCKOUT) to resist brute-force
  # guessing.
  def self.authenticate(email, candidate)
    find_authenticated(email, candidate).present?
  end

  # The authenticated record for +email+/+candidate+, or nil when the identity
  # does not exist, is locked out, or the PIN does not match. A successful match
  # resets the failure counter; a failed match increments it and locks the
  # identity once MAX_FAILED_ATTEMPTS is reached.
  def self.find_authenticated(email, candidate)
    return nil if candidate.blank?

    record = find_by(email_canonical: canonicalize(email))
    return nil if record.nil? || record.locked?

    if record.valid_pin?(candidate)
      record.reset_lock!
      record
    else
      record.register_failed_attempt!
      nil
    end
  end

  # Cryptographically-secure, uniformly-distributed 6-digit PIN ("000000".."999999").
  def self.generate_candidate
    SecureRandom.random_number(10**PIN_LENGTH).to_s.rjust(PIN_LENGTH, "0")
  end

  # Canonical identity key (trim + lowercase). A blank email has no PIN.
  def self.canonicalize(email)
    email.to_s.strip.downcase.presence
  end

  # HMAC-SHA256 digest of a PIN under a pepper derived from secret_key_base.
  def self.digest_for(pin)
    OpenSSL::HMAC.hexdigest("SHA256", pepper, pin.to_s)
  end

  # ── Instance API ───────────────────────────────────────────────────────────

  # Constant-time comparison of a candidate PIN against the stored digest.
  def valid_pin?(candidate)
    return false if candidate.blank?

    ActiveSupport::SecurityUtils.secure_compare(
      pin_digest.to_s,
      self.class.digest_for(candidate)
    )
  end

  # True when this identity is currently locked out (too many recent failures).
  def locked?
    locked_until.present? && locked_until > Time.current
  end

  # Record one failed authentication attempt and lock the identity once the
  # threshold is crossed. Lock duration grows exponentially on repeat lockouts.
  def register_failed_attempt!
    increment!(:failed_attempts)
    apply_lockout! if failed_attempts >= MAX_FAILED_ATTEMPTS
  end

  # Clear the failure counter and any lockout after a successful authentication.
  def reset_lock!
    return if failed_attempts.zero? && locked_until.nil?

    update!(failed_attempts: 0, locked_until: nil)
  end

  # Replace the PIN with a new collision-free value and return its plaintext so
  # the caller can show/email it. Raises if a unique PIN can't be found.
  def regenerate!
    MAX_COLLISION_ATTEMPTS.times do
      new_pin = self.class.generate_candidate
      begin
        update!(pin: new_pin, pin_digest: self.class.digest_for(new_pin))
        return new_pin
      rescue ActiveRecord::RecordNotUnique
        next # collided with another volunteer's PIN — try again
      end
    end

    raise "Unable to regenerate a unique PIN after #{MAX_COLLISION_ATTEMPTS} attempts"
  end

  private

  def self.create_for_email!(canonical)
    MAX_COLLISION_ATTEMPTS.times do
      pin = generate_candidate
      begin
        return create!(email_canonical: canonical, pin: pin, pin_digest: digest_for(pin))
      rescue ActiveRecord::RecordNotUnique
        # Two possible races: the email just got its PIN (concurrent submission)
        # or the randomly-chosen PIN collided with an existing one. Re-find by
        # email first; otherwise retry with a new PIN.
        existing = find_by(email_canonical: canonical)
        return existing if existing
      end
    end

    raise "Unable to assign a unique PIN after #{MAX_COLLISION_ATTEMPTS} attempts"
  end

  def self.pepper
    ENV["VOLUNTEER_PIN_PEPPER"].presence || Rails.application.secret_key_base
  end

  def normalize_email
    self.email_canonical = self.class.canonicalize(email_canonical)
  end

  def apply_lockout!
    update!(locked_until: Time.current + lockout_duration)
  end

  # Exponential backoff: the first lock is BASE_LOCKOUT, and each additional
  # failure beyond the threshold doubles it.
  def lockout_duration
    BASE_LOCKOUT * (2 ** [failed_attempts - MAX_FAILED_ATTEMPTS, 0].max)
  end
end
