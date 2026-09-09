# == Schema Information
#
# Table name: channel_whatsapp
#
#  id                             :bigint           not null, primary key
#  business_management_token      :text
#  message_templates              :jsonb
#  message_templates_last_updated :datetime
#  phone_number                   :string           not null
#  phone_number_health            :jsonb            not null
#  phone_number_health_checked_at :datetime
#  phone_number_health_error      :string
#  provider                       :string           default("default")
#  provider_config                :jsonb
#  created_at                     :datetime         not null
#  updated_at                     :datetime         not null
#  account_id                     :integer          not null
#
# Indexes
#
#  index_channel_whatsapp_on_phone_number                    (phone_number) UNIQUE
#  index_channel_whatsapp_on_phone_number_health_checked_at  (phone_number_health_checked_at)
#

class Channel::Whatsapp < ApplicationRecord
  include Channelable
  include Reauthorizable

  self.table_name = 'channel_whatsapp'
  EDITABLE_ATTRS = [:phone_number, :provider, { provider_config: {} }].freeze
  encrypts :business_management_token if Chatwoot.encryption_configured?

  # default at the moment is 360dialog lets change later.
  PROVIDERS = %w[default whatsapp_cloud baileys].freeze
  REACTION_SUPPORTED_PROVIDERS = %w[whatsapp_cloud baileys].freeze
  NEW_CHAT_CAP_KEYS = %w[capping_status ote_status mv_status total_quota used_quota cycle_start_timestamp cycle_end_timestamp].freeze
  before_validation :ensure_webhook_verify_token
  before_destroy :disconnect_channel_provider, if: -> { provider == 'baileys' && provider_service.respond_to?(:disconnect_channel_provider) }

  validates :provider, inclusion: { in: PROVIDERS }
  validates :phone_number, presence: true, uniqueness: true
  validate :validate_provider_config

  after_create :sync_templates
  after_update_commit :log_credentials_transfer, if: :saved_change_to_provider_config?
  before_destroy :teardown_webhooks
  after_commit :setup_webhooks, on: :create, if: :should_auto_setup_webhooks?

  def name
    'Whatsapp'
  end

  # Mirrors Channel::TwilioSms#voice_enabled? so the call subsystem can duck-type across providers.
  # Meta's Calling API is available to any whatsapp_cloud inbox (embedded-signup or manual keys);
  # only 360dialog (default provider) can't reach the call APIs.
  def voice_enabled?
    voice_calling_supported? &&
      provider_config['calling_enabled'].present? &&
      account.feature_enabled?('channel_voice')
  end

  # Mutes only the incoming side of calling; default on, so only an explicit false disables inbound.
  def inbound_calls_enabled?
    provider_config['inbound_calls_enabled'] != false
  end

  # Whether this inbox can do WhatsApp calling at all. Meta's Calling API is
  # reachable by any whatsapp_cloud inbox, so 360dialog inboxes can't be toggled
  # on even though calling_enabled would persist.
  def voice_calling_supported?
    provider == 'whatsapp_cloud'
  end

  def supports_reactions?
    REACTION_SUPPORTED_PROVIDERS.include?(provider)
  end

  def provider_service
    case provider
    when 'whatsapp_cloud'
      Whatsapp::Providers::WhatsappCloudService.new(whatsapp_channel: self)
    when 'baileys'
      Whatsapp::Providers::WhatsappBaileysService.new(whatsapp_channel: self)
    else
      Whatsapp::Providers::Whatsapp360DialogService.new(whatsapp_channel: self)
    end
  end

  def session_family?
    provider == 'baileys'
  end

  def session_capabilities
    Whatsapp::Session::Registry.capabilities_for(self)
  end

  def use_internal_host?
    provider == 'baileys' && ActiveModel::Type::Boolean.new.cast(ENV.fetch('BAILEYS_PROVIDER_USE_INTERNAL_HOST_URL', false))
  end

  def update_provider_connection!(provider_connection)
    provider_connection ||= {}
    normalized = provider_connection.deep_stringify_keys
    return if normalized == self.provider_connection

    assign_attributes(provider_connection: normalized)
    Inbox.no_touching { save!(validate: false) }
    broadcast_provider_connection_updated
  end

  def update_reachout_time_lock!(reachout_time_lock)
    return if reachout_time_lock.nil?

    with_lock do
      update_provider_connection!((provider_connection || {}).merge('reachout_time_lock' => reachout_time_lock))
    end
  end

  def update_new_chat_cap!(new_chat_cap)
    return if new_chat_cap.nil?

    normalized = new_chat_cap.to_h.deep_stringify_keys.slice(*NEW_CHAT_CAP_KEYS)
    with_lock do
      update_provider_connection!((provider_connection || {}).merge('new_chat_cap' => normalized))
    end
  end

  def provider_connection_data
    data = { connection: provider_connection.to_h['connection'] }
    %w[reachout_time_lock new_chat_cap send_stall].each do |key|
      data[key.to_sym] = provider_connection[key] if provider_connection.to_h[key].present?
    end
    data.merge!(provider_connection_admin_data) if Current.account_user&.administrator?
    data
  end

  def provider_connection_admin_data(connection = provider_connection)
    connection = connection.to_h
    { qr_data_url: connection['qr_data_url'], error: connection['error'] }
  end

  def disconnect_channel_provider
    provider_service.disconnect_channel_provider
  rescue StandardError => e
    raise unless destroyed? || @session_teardown

    Rails.logger.error "Failed to disconnect channel provider: #{e.message}"
  end

  def on_whatsapp(phone_number)
    return unless provider_service.respond_to?(:on_whatsapp)

    provider_service.on_whatsapp(phone_number)
  end

  delegate :setup_channel_provider, to: :provider_service
  delegate :import_session, to: :provider_service

  def broadcast_provider_connection_updated
    return if inbox.blank?

    Rails.configuration.dispatcher.sync_dispatcher.dispatch(
      Events::Types::INBOX_PROVIDER_CONNECTION_UPDATED, Time.zone.now,
      inbox: inbox, provider_connection: provider_connection
    )
  end

  def template_access_token
    return provider_config['api_key'] unless ChatwootApp.chatwoot_cloud? && provider_config['source'] == 'embedded_signup'

    business_management_token.presence || provider_config['api_key']
  end

  def serializable_hash(options = nil)
    super.except('business_management_token')
  end

  # Enables voice: turns calling on at Meta (idempotent), then re-registers webhooks
  # with the in-memory calling_enabled flag so the `calls` field is subscribed. The
  # flag is persisted only after registration succeeds, so a webhook failure can't
  # leave the inbox reporting voice_enabled? while the WABA isn't subscribed to calls.
  # Saved with validate: false to skip validate_provider_config's remote credential
  # re-check, which could spuriously fail and desync the flag from Meta.
  def enable_voice_calling!
    raise 'WhatsApp calling requires a whatsapp_cloud inbox' unless voice_calling_supported?
    raise 'WhatsApp calling requires the channel_voice feature' unless account.feature_enabled?('channel_voice')

    provider_service.update_calling_status('ENABLED')
    self.provider_config = provider_config.merge('calling_enabled' => true)
    webhook_setup_service.register_callback
    save!(validate: false)
  end

  # Disables voice: unsets calling_enabled (gates the call subsystem) and re-registers
  # webhooks, which drops `calls` from the subscription (best-effort, so a Meta outage
  # can't trap admins). Leaves Meta's WABA calling.status untouched.
  def disable_voice_calling!
    raise 'WhatsApp calling requires a whatsapp_cloud inbox' unless voice_calling_supported?

    self.provider_config = provider_config.merge('calling_enabled' => false)
    save!(validate: false)
    begin
      webhook_setup_service.register_callback
    rescue StandardError => e
      Rails.logger.warn "[WHATSAPP CALL] disable webhook re-subscribe failed: #{e.message}"
    end
  end

  # Whether the pending (unsaved) provider_config change drops the embedded_signup
  # source marker, i.e. this save is an embedded signup → manual setup transfer.
  def embedded_to_manual_transfer_pending?
    before, after = provider_config_change
    before&.dig('source') == 'embedded_signup' && after['source'] != 'embedded_signup'
  end

  def mark_message_templates_updated
    # rubocop:disable Rails/SkipsModelValidations
    update_column(:message_templates_last_updated, Time.zone.now)
    # rubocop:enable Rails/SkipsModelValidations
  end

  delegate :send_message, to: :provider_service
  delegate :send_template, to: :provider_service
  delegate :sync_templates, to: :provider_service
  delegate :media_url, to: :provider_service
  delegate :api_headers, to: :provider_service

  def send_contact_info_request(identifier, message)
    raise NotImplementedError, 'Contact information requests require a WhatsApp Cloud provider' unless provider == 'whatsapp_cloud'

    Whatsapp::Providers::WhatsappCloudContactInfoRequestService.perform(self, identifier, message)
  end

  def setup_webhooks(is_coexistence: nil)
    perform_webhook_setup(is_coexistence: is_coexistence)
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP] Webhook setup failed: #{e.message}"
    prompt_reauthorization!
  end

  private

  def ensure_webhook_verify_token
    provider_config['webhook_verify_token'] ||= SecureRandom.hex(16) if provider.in?(%w[whatsapp_cloud baileys])
  end

  def validate_provider_config
    errors.add(:provider_config, 'Invalid Credentials') unless provider_service.validate_provider_config?
  end

  # Logs only the embedded signup → manual migration (the save drops the
  # embedded_signup source marker), so credential rotations on inboxes that are
  # already manual stay silent.
  def log_credentials_transfer
    before, after = saved_change_to_provider_config
    return unless before&.dig('source') == 'embedded_signup' && after['source'] != 'embedded_signup'

    Rails.logger.info("[WHATSAPP_EMBEDDED_TO_MANUAL] success account_id=#{account_id} channel_id=#{id}")
  end

  def perform_webhook_setup(is_coexistence: nil)
    webhook_setup_service(is_coexistence: is_coexistence).perform
  end

  def webhook_setup_service(is_coexistence: nil)
    Whatsapp::WebhookSetupService.new(self, provider_config['business_account_id'], provider_config['api_key'], is_coexistence: is_coexistence)
  end

  def teardown_webhooks
    Whatsapp::WebhookTeardownService.new(self).perform
  end

  def should_auto_setup_webhooks?
    # Embedded signup and Manual V2 run webhook setup explicitly so their API
    # responses can reflect the real result instead of swallowing callback errors.
    explicitly_configured_sources = %w[embedded_signup manual_setup_v2]
    provider == 'whatsapp_cloud' && explicitly_configured_sources.exclude?(provider_config['source'])
  end
end

Channel::Whatsapp.prepend_mod_with('Channel::Whatsapp')
