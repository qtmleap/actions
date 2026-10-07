require "minitest/autorun"
require "tmpdir"
require_relative "../runtime/compatibility"
class CompatibilityTest < Minitest::Test
  class ConsumerError < StandardError; end
  def wrapper
    SharedCI.merge_wrapper(error_class: ConsumerError,
      config: { repository: "qtmleap/App", branches: %w[develop master], workflow: ".github/workflows/testflight.yaml",
                required_checks: { ".github/workflows/ci.yaml" => ["Policy"] }, record_only_paths: [] })
  end
  def test_public_constants_and_output
    klass = wrapper
    assert klass::Error < ConsumerError
    assert_equal ["Policy"], klass::REQUIRED.fetch(".github/workflows/ci.yaml")
    assert klass::Api < SharedCI::MergeVerifier::Api
    assert klass::Git < SharedCI::MergeVerifier::Git
    Dir.mktmpdir do |dir|
      file = File.join(dir, "out")
      klass.write_output(file, sha: "a" * 40, pr_number: 7)
      assert_equal "pr_number=7\nsha=#{'a' * 40}\n", File.read(file)
      assert_raises(klass::Error) { klass.write_output(file, sha: "invalid\noutput=forged", pr_number: 7) }
    end
  end
  def test_core_errors_are_translated
    klass = wrapper
    assert_raises(klass::Error) { klass::Api.new(token: "") }
    verifier = klass.new(env: {}, event: {}, api: Object.new, git: Object.new)
    assert_raises(klass::Error) { verifier.call }
  end
end
