require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require_relative "../runtime/legacy/build_copy"

class BuildCopyTest < Minitest::Test
  def test_archive_pipeline_extracts_exact_git_tree_without_credentials
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      repo, dest, bin = %w[repo dest bin].map { |name| File.join(dir, name) }
      FileUtils.mkdir_p([repo, bin])
      git = lambda do |*args, input: nil|
        output, status = Open3.capture2(SharedCI::Environment.child, "git", "-C", repo, *args, stdin_data: input || "", unsetenv_others: true)
        assert status.success?, args.inspect
        output.strip
      end
      git.call("init", "--quiet")
      blob = git.call("hash-object", "-w", "--stdin", input: "exact tree bytes\n")
      tree = git.call("mktree", input: "100644 blob #{blob}\ttracked.txt\n")
      File.write(File.join(repo, "untracked.txt"), "must not extract")
      real_git, status = Open3.capture2(SharedCI::Environment.child, "sh", "-c", "command -v git", unsetenv_others: true)
      assert status.success?
      captured = File.join(dir, "captured.json")
      File.write(File.join(bin, "git"), <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        abort "credentials leaked" if %w[SSH_AUTH_SOCK AMBIENT_SECRET BUNDLE_GITHUB__COM].any? { |name| ENV[name] }
        File.write(#{captured.inspect}, JSON.generate(ARGV))
        exec #{real_git.strip.inspect}, *ARGV
      RUBY
      File.chmod(0o755, File.join(bin, "git"))
      old = ENV.to_h
      begin
        ENV.update("PATH" => "#{bin}:#{ENV.fetch('PATH')}", "SSH_AUTH_SOCK" => "sentinel",
          "AMBIENT_SECRET" => "sentinel", "BUNDLE_GITHUB__COM" => "sentinel")
        assert_equal dest, BuildCopy.extract!(repo_root: repo, sha: tree, dest: dest)
        assert_equal "exact tree bytes\n", File.read(File.join(dest, "tracked.txt"))
        refute File.exist?(File.join(dest, "untracked.txt"))
        assert_equal ["-C", repo, "archive", "--format=tar", tree], JSON.parse(File.read(captured))
        assert_raises(BuildCopy::Error) { BuildCopy.extract!(repo_root: repo, sha: "0" * 40, dest: File.join(dir, "bad")) }
      ensure
        ENV.replace(old)
      end
    end
  end
end
