require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../runtime/bootstrap"
class BootstrapTest < Minitest::Test
  def setup
    @dir = File.realpath(Dir.mktmpdir)
    @app = File.join(@dir, "app")
    @root = File.join(@dir, "shared")
    FileUtils.mkdir_p(File.join(@app, ".github/workflows"))
    FileUtils.cp_r(File.expand_path("../runtime", __dir__), @root)
    # cp_r destination is itself runtime; normalize root layout.
    FileUtils.mv(@root, @root + "-runtime")
    FileUtils.mkdir_p(@root)
    FileUtils.mv(@root + "-runtime", File.join(@root, "runtime"))
    @revision = "0" * 40
    @lock = { "revision" => @revision, "runtime_files" => Dir.glob(File.join(@root, "runtime/**/*")).select { |p| File.file?(p) }.to_h { |p| [p.delete_prefix(@root + "/"), Digest::SHA256.file(p).hexdigest] } }
    save
    File.write(File.join(@app, ".github/workflows/ci.yaml"), "jobs:\n  test:\n    steps:\n      - uses: qtmleap/actions/actions/ruby-check@#{@revision}\n")
  end
  def teardown = FileUtils.remove_entry(@dir)
  def save = File.write(File.join(@app, ".github/shared-actions.lock.json"), JSON.generate(@lock))
  def verify(test: true)
    SharedCI::Bootstrap.verify!(root: @root, app_root: @app, revision: @revision, allow_test_revision: test)
  end
  def test_content_checked_even_with_test_pin
    assert_equal @root, verify
    assert_raises(SharedCI::Bootstrap::Error) { verify(test: false) }
    File.write(File.join(@root, "runtime/merge_verifier.rb"), "tampered")
    assert_raises(SharedCI::Bootstrap::Error) { verify }
  end
  def test_extra_files_and_missing_digests
    @lock["runtime_files"].delete("runtime/merge_verifier.rb")
    save
    assert_raises(SharedCI::Bootstrap::Error) { verify }
  end
  def test_yaml_pin_mismatch
    File.write(File.join(@app, ".github/workflows/ci.yaml"), "steps:\n  - uses: qtmleap/actions/actions/ruby-check@master\n")
    assert_raises(SharedCI::Bootstrap::Error) { verify }
  end
  def test_nested_repo_root_is_resolved_before_reading_lock
    env = { "GITHUB_WORKSPACE" => @dir, "SHARED_REPO_ROOT" => "app" }
    assert_equal @app, SharedCI::Bootstrap.app_root!(env)
    assert_equal @lock, SharedCI::Bootstrap.lock!(SharedCI::Bootstrap.app_root!(env))
    assert_equal @dir, SharedCI::Bootstrap.app_root!({ "GITHUB_WORKSPACE" => @dir })
    ["../app", "/app", "app\nforged", ""].each do |relative|
      assert_raises(SharedCI::Bootstrap::Error) { SharedCI::Bootstrap.app_root!(env.merge("SHARED_REPO_ROOT" => relative)) }
    end
    File.symlink(@app, File.join(@dir, "alias"))
    assert_raises(SharedCI::Bootstrap::Error) { SharedCI::Bootstrap.app_root!(env.merge("SHARED_REPO_ROOT" => "alias")) }
  end
  def test_symlink_and_escape
    File.symlink("merge_verifier.rb", File.join(@root, "runtime/link.rb"))
    assert_raises(SharedCI::Bootstrap::Error) { verify }
    @lock["runtime_files"]["runtime/../outside"] = "a" * 64
    save
    assert_raises(SharedCI::Bootstrap::Error) { verify }
  end
end
