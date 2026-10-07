require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "digest"
require "open3"
require "rbconfig"

class AppleToolchainTest < Minitest::Test
  HUB = File.expand_path("..", __dir__)
  REVISION = "1" * 40

  def fixture
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      runtime = File.join(dir, "runtime-only")
      app = File.join(dir, "app")
      bin = File.join(dir, "bin")
      developer = File.join(dir, "Developer")
      FileUtils.mkdir_p([runtime, bin, developer, File.join(app, ".github/workflows")])
      FileUtils.cp_r(File.join(HUB, "runtime"), runtime)
      files = Dir[File.join(runtime, "runtime/**/*")].select { |path| File.file?(path) }.sort.to_h do |path|
        [path.delete_prefix(runtime + "/"), Digest::SHA256.file(path).hexdigest]
      end
      File.write(File.join(app, ".github/shared-actions.lock.json"), JSON.generate(revision: REVISION, runtime_files: files))
      yaml = File.join(app, ".github/workflows/test.yml")
      File.write(yaml, "jobs:\n  toolchain:\n    steps:\n      - uses: qtmleap/actions/actions/apple-toolchain@#{REVISION}\n")
      { "uname" => 'case "$1" in -s) echo Darwin;; -m) echo arm64;; *) exit 1;; esac',
        "sw_vers" => 'echo 26.1', "xcodebuild" => 'printf "Xcode 26.2\\nBuild version fixture\\n"',
        "xcrun" => 'echo 26.1' }.each do |name, body|
        path = File.join(bin, name)
        File.write(path, "#!/bin/bash\nset -eu\n#{body}\n")
        File.chmod(0o755, path)
      end
      output = File.join(dir, "env")
      File.write(output, "before\n")
      env = { "PATH" => "#{bin}:#{File.dirname(RbConfig.ruby)}:/usr/bin:/bin", "HOME" => dir,
              "GITHUB_WORKSPACE" => app, "GITHUB_ENV" => output, "SHARED_REPO_ROOT" => ".",
              "SHARED_XCODE_VERSION" => "26", "SHARED_DEVELOPER_DIR" => developer,
              "QTMLEAP_ACTIONS_REVISION" => REVISION, "SHARED_ACTION_ROOT" => runtime }
      yield runtime, app, env, output, yaml
    end
  end

  def run_toolchain(env)
    Open3.capture2e(env, "/bin/bash", File.join(HUB, "runtime/apple-toolchain.sh"), unsetenv_others: true)
  end

  def test_runtime_only_root_uses_real_bootstrap_and_exports_verified_root
    fixture do |runtime, _app, env, output, _yaml|
      refute Dir.exist?(File.join(runtime, "actions"))
      text, status = run_toolchain(env)
      assert status.success?, text
      assert_includes File.read(output), "QTMLEAP_ACTIONS_ROOT=#{runtime}\n"
      assert_includes File.read(output), "QTMLEAP_ACTIONS_REVISION=#{REVISION}\n"
    end
  end

  def test_composite_action_path_keeps_the_existing_default
    fixture do |_runtime, _app, env, output, _yaml|
      env.delete("SHARED_ACTION_ROOT")
      env["SHARED_ACTION_PATH"] = File.join(HUB, "actions/apple-toolchain")
      text, status = run_toolchain(env)
      assert status.success?, text
      assert_includes File.read(output), "QTMLEAP_ACTIONS_ROOT=#{File.realpath(HUB)}\n"
    end
  end

  def test_runtime_only_root_still_rejects_digest_and_workflow_mismatches
    [:digest, :workflow].each do |mutation|
      fixture do |runtime, _app, env, output, yaml|
        if mutation == :digest
          File.write(File.join(runtime, "runtime/environment.rb"), "tampered\n")
        else
          File.write(yaml, "uses: qtmleap/actions/actions/apple-toolchain@#{'2' * 40}\n")
        end
        _text, status = run_toolchain(env)
        refute status.success?, mutation.to_s
        assert_equal "before\n", File.read(output)
      end
    end
  end
end
