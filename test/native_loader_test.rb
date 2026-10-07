require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "digest"
require "json"
require "rbconfig"
require_relative "../templates/shared_actions_loader"
class NativeLoaderTest < Minitest::Test
  def test_cold_public_bootstrap_and_tampered_cache_rejection
    cold_bootstrap
  end
  def test_native_bootstrap_without_runner_temp
    cold_bootstrap(with_runner_temp: false)
  end
  def cold_bootstrap(with_runner_temp: true)
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      app, temp, bin = %w[app temp bin].map { |name| File.join(dir, name) }
      FileUtils.mkdir_p([File.join(app, ".github/workflows"), temp, bin])
      root = File.expand_path("..", __dir__)
      revision = "a" * 40
      files = Dir.glob(File.join(root, "runtime/**/*")).select { |p| File.file?(p) }.to_h { |p| [p.delete_prefix(root + "/"), Digest::SHA256.file(p).hexdigest] }
      File.write(File.join(app, ".github/shared-actions.lock.json"), JSON.generate({ revision: revision, runtime_files: files }))
      File.write(File.join(app, ".github/workflows/ci.yml"), "steps:\n - uses: qtmleap/actions/actions/run-adapter@#{revision}\n")
      log = File.join(dir, "git.jsonl")
      File.write(File.join(bin, "git"), <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        require "fileutils"
        abort "credential leaked" if %w[GITHUB_TOKEN TESTFLIGHT_ASC_KEY_CONTENT SSH_AUTH_SOCK AMBIENT_SECRET BUNDLE_GITHUB__COM].any? { |name| ENV[name] }
        File.open(#{log.inspect}, "a") { |f| f.puts JSON.generate(ARGV) }
        stage = ARGV[1]
        args = ARGV.drop(2)
        case args.first
        when "init", "-c", "fsck" then nil
        when "rev-parse" then puts #{revision.inspect}
        when "checkout"
          abort "invalid path checkout arguments" unless args == ["checkout", #{revision.inspect}, "--", "runtime"]
          FileUtils.cp_r(#{File.join(root, "runtime").inspect}, stage)
        else abort "unexpected command"
        end
      RUBY
      File.chmod(0o755, File.join(bin, "git"))
      saved = ENV.to_h
      begin
        ENV.update("RUNNER_TEMP" => temp, "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "GITHUB_TOKEN" => "sentinel",
          "SSH_AUTH_SOCK" => "sentinel", "AMBIENT_SECRET" => "sentinel", "BUNDLE_GITHUB__COM" => "sentinel")
        unless with_runner_temp
          ENV.delete("RUNNER_TEMP")
          ENV["TMPDIR"] = temp
        end
        ENV.delete("QTMLEAP_ACTIONS_ROOT")
        ENV.delete("QTMLEAP_ACTIONS_REVISION")
        verified = SharedActionsLoader.load!(app_root: app)
        assert verified.start_with?(temp + "/")
        calls = File.readlines(log).map { |line| JSON.parse(line) }
        assert calls.any? { |args| args.include?("https://github.com/qtmleap/actions.git") && args.last == revision }
        assert calls.any? { |args| args.include?("fsck") }
        assert_equal [["checkout", revision, "--", "runtime"]], calls.map { |args| args.drop(2) }.select { |args| args.first == "checkout" }
        File.write(File.join(verified, "runtime/merge_verifier.rb"), "tampered")
        assert_raises(RuntimeError) { SharedActionsLoader.load!(app_root: app) }
        ENV.delete("QTMLEAP_ACTIONS_ROOT")
        assert_raises(RuntimeError) { SharedActionsLoader.load!(app_root: app) }
        assert_equal calls.length, File.readlines(log).length, "tampered cache was silently fetched again"
      ensure
        ENV.replace(saved)
      end
    end
  end
end
