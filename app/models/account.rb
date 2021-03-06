require 'activerecord/uuid'

class Account < ActiveRecord::Base
  include ActiveRecord::UUID
  extend FriendlyId

  belongs_to :billing_plan

  friendly_id :account_slug, :use => :slugged

  has_many :conversations, :dependent => :destroy
  has_many :people, :dependent => :destroy

  has_many :memberships, :dependent => :destroy
  has_many :users, through: :memberships

  has_many :webhooks, :dependent => :destroy

  attr_accessor :new_account_user

  validates :name, presence: true
  validates :slug, presence: true

  before_create :generate_webhook_secret
  after_create :save_new_user

  # Internal: Regex to extract an account slug from a Account#mailbox address
  MAILBOX_REGEX = Regexp.new(/^(?<slug>(\w|-)+)(\+\w+)?@.+$/).freeze

  # Candidates for how to generate the slug.
  def account_slug
    [:name]
  end

  # Public: Customer specific email address for incoming email.
  #
  # Returns the email address customers should send email to.
  def mailbox
    email = Mail::Address.new([
      slug,
      '@',
      Helpful.incoming_email_domain
    ].join.to_s)

    email.display_name = name

    return email
  end

  # Public: Given an email address try to match to an account.
  #
  # Returns one Account or nil.
  def self.match_mailbox(email)
    address = Mail::Address.new(email).address
    slug = MAILBOX_REGEX.match(address)[:slug]
    self.where(slug: slug).first
  end

  # Public: Given an email address try to match to an account or raise
  # ActiveRecord::RecordNotFound.
  #
  # Returns one Account or raises ActiveRecord::RecordNotFound.
  def self.match_mailbox!(email)
    self.match_mailbox(email) || raise(ActiveRecord::RecordNotFound)
  end

  # Overrides the portal url attribute to regenerate every few days with a newly valid link
  def chargify_portal_url

    if self[:chargify_portal_url].blank? || chargify_portal_valid_until < Time.zone.now
      if self.chargify_customer_id.to_i > 0 # In dev it's possibly we 'faked' it.  If so, we don't want to hit Chargify with an invalid request

        new_url, expiration = Chargify.management_url(self.chargify_customer_id)
        if new_url
          self.update_attributes({chargify_portal_url: new_url, chargify_portal_valid_until: expiration})
        end

      end
    end

    self[:chargify_portal_url] || ''
  end

  # Retrieves the latest subscription info and saves it to the account
  def get_update_from_chargify!
    self.chargify_subscription_id ||= Chargify.subscription_id_from_customer_reference(self.id)

    if chargify_subscription_id
      r = Chargify.subscription_status(chargify_subscription_id)

      if r
        self.billing_status = r['subscription']['state']
        self.billing_plan   = BillingPlan.find_by_slug r['subscription']['product']['handle']
        self.chargify_customer_id = r['subscription']['customer']['id']

        self.save!
      end
    end
  end

  protected

  def save_new_user
    if new_account_user
      new_account_user.save || raise(ActiveRecord::Rollback)
      Membership.create(account: self, user: new_account_user, role: 'owner') || raise(ActiveRecord::Rollback)
    end
  end

  def generate_webhook_secret
    self.webhook_secret = SecureRandom.hex(16)
  end
end
