require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../runtime/actions"
class ActionsTest < Minitest::Test
  def setup
    @dir = File.realpath(Dir.mktmpdir)
    @app = File.join(@dir, "app")
    @root = File.expand_path("..", __dir__)
    FileUtils.mkdir_p(File.join(@app, ".github/workflows"))
    @revision = "a" * 40
    files = Dir.glob(File.join(@root, "runtime/**/*")).select { |p| File.file?(p) }.to_h { |p| [p.delete_prefix(@root + "/"), Digest::SHA256.file(p).hexdigest] }
    File.write(File.join(@app, ".github/shared-actions.lock.json"), JSON.generate({ revision: @revision, runtime_files: files }))
    File.write(File.join(@app, ".github/workflows/ci.yml"), "steps:\n - uses: qtmleap/actions/actions/run-adapter@#{@revision}\n")
    File.write(File.join(@app, "adapter.rb"), 'require "json"; File.write(ENV.fetch("CAPTURE"), JSON.generate({argv: ARGV, token: ENV["TESTFLIGHT_ASC_KEY_CONTENT"], root: ENV["QTMLEAP_ACTIONS_ROOT"]}))')
    @capture = File.join(@dir, "capture.json")
    @old = ENV.to_h
    ENV.update("GITHUB_WORKSPACE" => @app, "SHARED_ACTION_ROOT" => @root, "SHARED_ADAPTER" => "adapter.rb",
      "SHARED_OPERATION" => "cleanup", "SHARED_ARGV_JSON" => '["literal; not shell", "with space"]',
      "TESTFLIGHT_ASC_KEY_CONTENT" => "sentinel", "CAPTURE" => @capture)
    ENV.delete("QTMLEAP_ACTIONS_REVISION")
    ENV.delete("GITHUB_ENV")
    ENV.delete("SHARED_REPO_ROOT")
    ENV.delete("SHARED_WORKING_DIRECTORY")
  end
  def teardown
    ENV.replace(@old)
    FileUtils.remove_entry(@dir)
  end
  def test_cleanup_is_credential_free_and_argv_is_literal
    SharedCI::Actions.execute("run-adapter")
    data = JSON.parse(File.read(@capture))
    assert_nil data["token"]
    assert_equal ["cleanup", "literal; not shell", "with space"], data["argv"]
    assert_equal @root, data["root"]
  end
  def test_invalid_operation_and_argv_stop_before_execution
    ENV["SHARED_OPERATION"] = "cleanup; evil"
    assert_raises(ArgumentError) { SharedCI::Actions.execute("run-adapter") }
    ENV["SHARED_OPERATION"] = "cleanup"
    ENV["SHARED_ARGV_JSON"] = '{"command":"evil"}'
    assert_raises(ArgumentError) { SharedCI::Actions.execute("run-adapter") }
    refute File.exist?(@capture)
  end
  def test_success_exit_without_verified_outputs_is_rejected
    ENV.update("SHARED_ADAPTER" => "verify.rb", "SHARED_GITHUB_TOKEN" => "test-token",
      "GITHUB_OUTPUT" => File.join(@dir, "out"), "GITHUB_SHA" => "a" * 40)
    File.write(File.join(@app, "verify.rb"), 'File.write(ENV.fetch("GITHUB_OUTPUT"), "sha=forged\\npr_number=7\\n")')
    assert_raises(ArgumentError) { SharedCI::Actions.execute("verify-merge") }
    File.write(File.join(@app, "verify.rb"), 'abort "credential leaked" if ENV["TESTFLIGHT_ASC_KEY_CONTENT"]; abort "missing read token" unless ENV["GITHUB_TOKEN"] == "test-token"; File.write(ENV.fetch("GITHUB_OUTPUT"), "sha=#{ENV.fetch("GITHUB_SHA")}\\npr_number=7\\n")')
    SharedCI::Actions.execute("verify-merge")
    assert_includes File.read(ENV.fetch("GITHUB_OUTPUT")), "pr_number=7"
  end
  def test_nested_checkout_adapter_and_relative_record_paths
    nested = File.join(@dir, "workspace/Kotatsu")
    FileUtils.mkdir_p(File.dirname(nested))
    FileUtils.mv(@app, nested)
    ENV.update("GITHUB_WORKSPACE" => File.dirname(nested), "SHARED_REPO_ROOT" => "Kotatsu")
    SharedCI::Actions.execute("run-adapter")
    assert_equal @root, JSON.parse(File.read(@capture))["root"]
    temp = File.join(@dir, "temp")
    FileUtils.mkdir_p(temp)
    File.write(File.join(nested, "receipt.json"), JSON.generate({ sha: "a" * 40, upload_result: "uploaded" }))
    ENV.update("RUNNER_TEMP" => temp, "GITHUB_OUTPUT" => File.join(@dir, "outputs"),
      "SHARED_RECORD_PATH" => "receipt.json", "GITHUB_SHA" => "a" * 40)
    SharedCI::Actions.execute("release-record")
    assert_includes File.read(ENV.fetch("GITHUB_OUTPUT")), "found=true"
    # A tracked receipt from the previous merge must not become this run's artifact.
    ENV["GITHUB_SHA"] = "b" * 40
    File.write(ENV.fetch("GITHUB_OUTPUT"), "")
    assert_raises(SharedCI::Records::Error) { SharedCI::Actions.execute("release-record") }
    assert_empty File.read(ENV.fetch("GITHUB_OUTPUT"))
  end
  def test_fresh_receipt_is_preserved_after_actual_cleanup_adapter_failure
    File.write(File.join(@app, "adapter.rb"), 'abort "cleanup restoration failed"')
    assert_raises(RuntimeError) { SharedCI::Actions.execute("run-adapter") }
    temp = File.join(@dir, "temp")
    FileUtils.mkdir_p(temp)
    receipt = File.join(@app, "fresh.json")
    File.write(receipt, JSON.generate({ source_sha: "a" * 40, upload_result: "uploaded" }))
    ENV.update("RUNNER_TEMP" => temp, "GITHUB_OUTPUT" => File.join(@dir, "outputs"),
      "SHARED_RECORD_PATH" => "fresh.json", "GITHUB_SHA" => "a" * 40)
    SharedCI::Actions.execute("release-record")
    assert_includes File.read(ENV.fetch("GITHUB_OUTPUT")), "found=true"
    snapshots = Dir.glob(File.join(temp, "shared-receipts-*/fresh.json"))
    assert_equal 1, snapshots.length
    assert_equal "uploaded", JSON.parse(File.read(snapshots.first))["upload_result"]
    assert File.exist?(receipt)
  end
  def test_noncleanup_adapter_receives_only_explicit_step_environment
    env = ENV.to_h.merge("SHARED_OPERATION" => "release")
    env.delete("TESTFLIGHT_ASC_KEY_CONTENT")
    SharedCI::Actions.execute("run-adapter", env)
    assert_nil JSON.parse(File.read(@capture))["token"]
    env["TESTFLIGHT_ASC_KEY_CONTENT"] = "explicit-step"
    SharedCI::Actions.execute("run-adapter", env)
    assert_equal "explicit-step", JSON.parse(File.read(@capture))["token"]
  end
  def test_adapter_cannot_escape_source
    ENV["SHARED_ADAPTER"] = "../adapter.rb"
    assert_raises(ArgumentError) { SharedCI::Actions.execute("run-adapter") }
    refute File.exist?(@capture)
  end
end
