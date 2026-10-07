# frozen_string_literal: true
module SharedCI
  LEGACY = %w[build_copy build_number credentials deployment_policy fastlane_adapter git_state ipa_verifier
              keychain merge_verifier package_auth release_pipeline].freeze
  def self.load_legacy(name, app_root:)
    raise ArgumentError, "Unknown legacy module" unless LEGACY.include?(name.to_s)
    root = File.realpath(app_root)
    raise ArgumentError, "One app root per process" if @legacy_app_root && @legacy_app_root != root
    unless @legacy_app_root
      raise ArgumentError, "Config was loaded outside the shared loader" if defined?(::ReleaseConfig)
      require File.join(root, "fastlane/lib/release_config.rb")
      raise ArgumentError, "Consumer ReleaseConfig missing" unless defined?(::ReleaseConfig)
      @legacy_app_root = root
    end
    require File.join(__dir__, "legacy", name.to_s)
  end
end
