# frozen_string_literal: true
module SharedCI
  module Environment
    EXACT = %w[GITHUB_TOKEN GH_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN RELEASE_SOURCE_READ_TOKEN
               GIT_ASKPASS SSH_ASKPASS SSH_AUTH_SOCK SSH_AGENT_PID GIT_SSH GIT_SSH_COMMAND GIT_CONFIG_PARAMETERS FASTLANE_PASSWORD FASTLANE_SESSION
               FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD ACTIONS_RUNTIME_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN
               ACTIONS_ID_TOKEN_REQUEST_URL RUBYOPT RUBYLIB RUBYGEMS_GEMDEPS].freeze
    PREFIXES = %w[ASC_ APP_STORE_CONNECT_API_KEY_ MATCH_ TESTFLIGHT_ MUSICFIN_ QUANTUMLEAP_ GIT_CONFIG_ INPUT_ BUNDLER_].freeze
    module_function
    def credential_name?(name)
      (name.start_with?("BUNDLE_") && !%w[BUNDLE_PATH BUNDLE_APP_CONFIG BUNDLE_FROZEN BUNDLE_IGNORE_CONFIG].include?(name)) ||
        EXACT.include?(name) || PREFIXES.any? { |prefix| name.start_with?(prefix) } ||
        name.match?(/(?:TOKEN|PASSWORD|PRIVATE_KEY|KEY_CONTENT|SECRET|AUTHORIZATION|SPARKLE)/i)
    end
    def child(env = ENV)
      (ENV.keys | env.keys).to_h do |name|
        [name, credential_name?(name) ? nil : env[name]]
      end
    end
  end
end
