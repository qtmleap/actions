require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "shellwords"
require "json"
require "digest"
require "rbconfig"
class SetupRubyTest < Minitest::Test
  def test_job_owned_locked_frozen_install_without_credentials
    setup_fixture
  end
  def test_nested_checkout_locked_install
    setup_fixture(nested: true)
  end
  def setup_fixture(nested: false)
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      root = File.expand_path("..", __dir__)
      workspace = File.join(dir, "app")
      app = nested ? File.join(workspace, "Kotatsu") : workspace
      home = File.join(dir, "home")
      bin = File.join(home, ".rbenv/versions/3.4.10/bin")
      temp = File.join(dir, "temp")
      FileUtils.mkdir_p([bin, temp, File.join(app, ".github/workflows")])
      revision = "a" * 40
      files = Dir.glob(File.join(root, "runtime/**/*")).select { |p| File.file?(p) }.to_h { |p| [p.delete_prefix(root + "/"), Digest::SHA256.file(p).hexdigest] }
      File.write(File.join(app, ".github/shared-actions.lock.json"), JSON.generate({ revision: revision, runtime_files: files }))
      File.write(File.join(app, ".github/workflows/ci.yml"), "steps:\n - uses: qtmleap/actions/actions/setup-ruby@#{revision}\n")
      File.write(File.join(app, "Gemfile.lock"), "BUNDLED WITH\n   2.6.9\n")
      File.write(File.join(bin, "ruby"), "#!/usr/bin/env bash\nif [[ \"${2:-}\" == 'print RUBY_ENGINE + \":\" + RUBY_VERSION' ]]; then printf ruby:3.4.10; else exec #{Shellwords.escape(RbConfig.ruby)} \"$@\"; fi\n")
      log = File.join(dir, "commands")
      %w[gem bundle].each do |cmd|
        File.write(File.join(bin, cmd), "#!/usr/bin/env bash\nset -e\n[[ -z \"${TESTFLIGHT_ASC_KEY_CONTENT:-}\" && -z \"${BUNDLE_GITHUB__COM:-}\" ]]\n[[ \"$GEM_HOME\" == \"$RUNNER_TEMP\"/* && \"$BUNDLE_FROZEN\" == true ]]\n[[ \"$BUNDLE_APP_CONFIG\" == \"$RUNNER_TEMP\"/* && \"$BUNDLE_PATH\" == \"$RUNNER_TEMP\"/* ]]\n[[ \"$FL_REPORT_PATH\" == \"$RUNNER_TEMP\"/* && -d \"$FL_REPORT_PATH\" && \"$FASTLANE_SKIP_DOCS\" == true ]]\n[[ -z \"${SSH_AUTH_SOCK:-}\" && -z \"${AMBIENT_SECRET:-}\" ]]\nprintf '%s %s\\n' #{cmd} \"$*\" >> #{Shellwords.escape(log)}\n")
      end
      %w[ruby gem bundle].each { |cmd| File.chmod(0o755, File.join(bin, cmd)) }
      env = { "HOME" => home, "RUNNER_TEMP" => temp, "GITHUB_WORKSPACE" => workspace, "SHARED_REPO_ROOT" => nested ? "Kotatsu" : ".",
              "GITHUB_PATH" => File.join(dir, "path"), "GITHUB_ENV" => File.join(dir, "env"),
              "SHARED_RUBY_VERSION" => "3.4.10", "SHARED_ACTION_PATH" => File.join(root, "actions/setup-ruby"),
              "SHARED_WORKING_DIRECTORY" => ".", "QTMLEAP_ACTIONS_REVISION" => revision,
              "TESTFLIGHT_ASC_KEY_CONTENT" => "sentinel", "BUNDLE_GITHUB__COM" => "sentinel",
              "SSH_AUTH_SOCK" => "sentinel", "AMBIENT_SECRET" => "sentinel",
              "FL_REPORT_PATH" => File.join(app, "report"), "FASTLANE_SKIP_DOCS" => "false" }
      output, status = Open3.capture2e(env, "bash", File.join(root, "runtime/setup-ruby.sh"))
      assert status.success?, output
      assert_includes File.read(log), "gem install bundler --version 2.6.9 --no-document"
      assert_includes File.read(log), "bundle _2.6.9_ install"
      assert_includes File.read(env.fetch("GITHUB_ENV")), "BUNDLE_FROZEN=true"
      refute_includes File.read(env.fetch("GITHUB_ENV")), "sentinel"
      assert_includes File.read(env.fetch("GITHUB_ENV")), "FASTLANE_SKIP_DOCS=true"
      refute File.exist?(File.join(app, "report"))
      File.write(File.join(app, "Gemfile.lock"), "missing Bundler")
      _, status = Open3.capture2e(env, "bash", File.join(root, "runtime/setup-ruby.sh"))
      refute status.success?
    end
  end
end
