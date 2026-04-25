# frozen_string_literal: true

# =============================================================================
#   Chatwoot Enterprise Unlocker (self-hosted, single-file patch)
# =============================================================================
# Mounted as a read-only volume at /app/config/initializers/zz_unlock_enterprise.rb
# Loaded last because of the "zz_" prefix, after every official initializer.
#
# Five layers of protection (each one survives if the others fail):
#   1. ChatwootHub.pricing_plan / pricing_plan_quantity hardcoded to enterprise
#   2. ChatwootHub telemetry & registration calls turned into no-ops
#   3. Internal::ReconcilePlanConfigService#perform turned into a no-op
#   4. Account#after_create_commit hook unlocks features in NEW accounts
#   5. Boot-time pass: persists InstallationConfig and unlocks EXISTING accounts
#
# Single source of truth: editing this file is the only thing required to
# adjust the unlock behavior. No upstream Ruby file is replaced.
# =============================================================================

module EnterpriseUnlocker
  PREMIUM_PLAN_FEATURES = %w[
    inbound_emails
    help_center
    campaigns
    team_management
    channel_facebook
    channel_email
    channel_instagram
    captain_integration
    advanced_search_indexing
    advanced_search
    linear_integration
    sla
    custom_roles
    csat_review_notes
    conversation_required_attributes
    advanced_assignment
    custom_tools
    audit_logs
    disable_branding
    saml
  ].freeze

  PLAN_NAME = 'Enterprise'
  PLAN_QUANTITY = 10_000

  module_function

  def apply_all
    apply_installation_config
    apply_account_unlocks
  end

  def apply_to_account(account)
    enable_features(account)
    set_plan_attribute(account)
  end

  def apply_installation_config
    upsert_config('INSTALLATION_PRICING_PLAN', 'enterprise')
    upsert_config('INSTALLATION_PRICING_PLAN_QUANTITY', PLAN_QUANTITY)
    GlobalConfig.clear_cache if defined?(GlobalConfig)
  end

  def upsert_config(name, value)
    config = InstallationConfig.find_or_initialize_by(name: name)
    return if config.persisted? && config.value == value && !config.locked

    config.value = value
    config.locked = false
    config.save!
    Rails.logger.info "[unlock] installation_config #{name}=#{value}"
  end

  def apply_account_unlocks
    return unless ActiveRecord::Base.connection.data_source_exists?('accounts')

    Account.find_each { |account| apply_to_account(account) }
  end

  def enable_features(account)
    missing = PREMIUM_PLAN_FEATURES.reject { |f| feature_safely_enabled?(account, f) }
    return if missing.empty?

    account.enable_features(*missing)
    account.save!
    Rails.logger.info "[unlock] account=#{account.id} enabled: #{missing.join(',')}"
  end

  def set_plan_attribute(account)
    attrs = account.custom_attributes || {}
    return if attrs['plan_name'] == PLAN_NAME

    account.update_columns(custom_attributes: attrs.merge('plan_name' => PLAN_NAME))
  end

  def feature_safely_enabled?(account, feature)
    account.feature_enabled?(feature)
  rescue NoMethodError
    true
  end
end

# Layer 1 + 2: lock pricing_plan and silence outbound telemetry
Rails.application.config.to_prepare do
  next unless defined?(ChatwootHub)

  ChatwootHub.singleton_class.class_eval do
    define_method(:pricing_plan) { 'enterprise' }
    define_method(:pricing_plan_quantity) { EnterpriseUnlocker::PLAN_QUANTITY }
    define_method(:sync_with_hub) { {} }
    define_method(:register_instance) { |*_args| nil }
    define_method(:emit_event) { |*_args| nil }
    define_method(:send_push) { |*_args| nil }
  end
end

# Layer 3: neutralize the periodic plan reconciliation job
Rails.application.config.to_prepare do
  next unless defined?(Internal::ReconcilePlanConfigService)

  Internal::ReconcilePlanConfigService.class_eval do
    define_method(:perform) { nil }
  end
end

# Layer 4: hook future Account creations (no need to restart after signup)
Rails.application.config.to_prepare do
  next unless defined?(Account)
  next if Account.respond_to?(:__enterprise_unlock_hooked__)

  Account.after_create_commit do
    EnterpriseUnlocker.apply_to_account(self)
  rescue StandardError => e
    Rails.logger.warn "[unlock] account-hook failed (id=#{id}): #{e.class}: #{e.message}"
  end

  Account.define_singleton_method(:__enterprise_unlock_hooked__) { true }
end

# Layer 5: one-shot boot pass for installation config + existing accounts
Rails.application.config.after_initialize do
  next if defined?(Rails::Console) || $PROGRAM_NAME.end_with?('rake')

  Thread.new do
    sleep 8

    begin
      next unless ActiveRecord::Base.connection.data_source_exists?('installation_configs')

      EnterpriseUnlocker.apply_all
    rescue StandardError => e
      Rails.logger.warn "[unlock] boot pass skipped: #{e.class}: #{e.message}"
    ensure
      ActiveRecord::Base.connection_pool.release_connection rescue nil
    end
  end
end
