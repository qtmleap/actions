require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require_relative "../runtime/environment"

class EnvironmentTest < Minitest::Test
  def setup
    @old = ENV.to_h
    ENV.update("SSH_AUTH_SOCK" => "agent", "AMBIENT_SECRET" => "sentinel",
      "BUNDLE_GITHUB__COM" => "registry-password", "UNRELATED_AMBIENT" => "ambient")
  end
  def teardown = ENV.replace(@old)
  def test_explicit_environment_uses_only_provided_noncredentials
    provided = { "PATH" => ENV.fetch("PATH"), "KEEP" => "value",
      "BUNDLE_PATH" => "/owned/bundle", "BUNDLE_APP_CONFIG" => "/owned/config",
      "BUNDLE_FROZEN" => "true", "BUNDLE_IGNORE_CONFIG" => "1",
      "SSH_AUTH_SOCK" => "provided-agent", "BUNDLE_GITHUB__COM" => "password" }
    child = SharedCI::Environment.child(provided)
    %w[SSH_AUTH_SOCK AMBIENT_SECRET BUNDLE_GITHUB__COM UNRELATED_AMBIENT].each { |key| assert_nil child[key] }
    provided.each { |key, value| assert_equal value, child[key] unless SharedCI::Environment.credential_name?(key) }
    output, status = Open3.capture2(child, RbConfig.ruby, "-rjson", "-e", "puts JSON.generate(ENV.to_h)", unsetenv_others: true)
    assert status.success?
    actual = JSON.parse(output)
    %w[SSH_AUTH_SOCK AMBIENT_SECRET BUNDLE_GITHUB__COM UNRELATED_AMBIENT].each { |key| refute actual.key?(key) }
    assert_equal "value", actual["KEEP"]
    assert_equal "/owned/config", actual["BUNDLE_APP_CONFIG"]
  end
  def test_empty_provided_environment_cannot_inherit_ambient_authority
    child = SharedCI::Environment.child({})
    assert ENV.keys.all? { |key| child.key?(key) && child[key].nil? }
    output, status = Open3.capture2(child, RbConfig.ruby, "-rjson", "-e", "puts JSON.generate(ENV.to_h)", unsetenv_others: true)
    assert status.success?
    actual = JSON.parse(output)
    # macOS は起動時に文字コードの情報を補うため、親からの認証継承とは区別する。
    actual.delete("__CF_USER_TEXT_ENCODING") if RUBY_PLATFORM.include?("darwin")
    assert_empty actual
  end
  def test_default_preserves_noncredentials_but_not_registry_or_agent
    child = SharedCI::Environment.child
    assert_equal "ambient", child["UNRELATED_AMBIENT"]
    %w[SSH_AUTH_SOCK AMBIENT_SECRET BUNDLE_GITHUB__COM].each { |key| assert_nil child[key] }
  end
  def test_tool_children_cannot_execute_ambient_ruby_loader_code
    ENV.update("RUBYOPT" => "-rfixture-missing-loader", "RUBYLIB" => "/fixture/ambient-loader", "RUBYGEMS_GEMDEPS" => "fixture-gems.rb")
    child = SharedCI::Environment.child
    %w[RUBYOPT RUBYLIB RUBYGEMS_GEMDEPS].each { |key| assert_nil child[key] }
    output, status = Open3.capture2e(child, RbConfig.ruby, "-rjson", "-e", "puts JSON.generate(ENV.keys.grep(/^RUBYOPT$|^RUBYLIB$|^RUBYGEMS_GEMDEPS$/))", unsetenv_others: true)
    assert status.success?, output
    assert_empty JSON.parse(output)
  end
end
