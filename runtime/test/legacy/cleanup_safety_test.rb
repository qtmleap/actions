require_relative "test_helper"
require "open3"

def cleanup_fixture
  Dir.mktmpdir do |dir|
    temp = File.join(dir, "runner")
    home = File.join(dir, "home")
    work = File.join(temp, "work")
    state = File.join(temp, "release-state")
    bin = File.join(dir, "bin")
    FileUtils.mkdir_p([work, state, home, bin])
    File.write(File.join(home, ".netrc"), "temporary")
    File.write(File.join(state, "original.netrc"), "original")
    calls = File.join(dir, "security-calls")
    leaks = File.join(dir, "security-leaks")
    File.write(File.join(bin, "security"), <<~SH)
      #!/usr/bin/env bash
      for name in ASC_KEY_CONTENT MATCH_PASSWORD TESTFLIGHT_ASC_KEY_CONTENT TESTFLIGHT_MATCH_GIT_TOKEN; do
        [[ -z "${!name+x}" ]] || printf '%s\\n' "$name" >> #{leaks.inspect}
      done
      printf '%s\\n' "$*" >> #{calls.inspect}
      exit 0
    SH
    File.chmod(0o755, File.join(bin, "security"))
    env = { "RUNNER_TEMP" => temp, "RELEASE_WORK" => work, "HOME" => home,
            "PATH" => "#{bin}:#{ENV.fetch('PATH')}" }
    script = File.expand_path("../../legacy/ci-release-cleanup.sh", __dir__)
    yield dir, temp, home, work, state, env, script, calls, leaks
  end
end

check "cleanup rejects traversal before recovering netrc or deleting an outside directory" do
  cleanup_fixture do |dir, temp, home, _work, state, env, script, calls, _leaks|
    victim = File.join(dir, "victim")
    FileUtils.mkdir_p(victim)
    File.write(File.join(victim, "keep"), "owned elsewhere")
    _, status = Open3.capture2e(env.merge("RELEASE_WORK" => File.join(temp, "../victim")), "bash", script)
    assert !status.success?, "traversal cleanup was accepted"
    assert File.read(File.join(victim, "keep")) == "owned elsewhere"
    assert File.read(File.join(home, ".netrc")) == "temporary"
    assert File.read(File.join(state, "original.netrc")) == "original"
    assert !File.exist?(calls)
  end
end

check "cleanup rejects outside work before touching the recovery journal" do
  cleanup_fixture do |dir, _temp, home, _work, state, env, script, _calls, _leaks|
    _, status = Open3.capture2e(env.merge("RELEASE_WORK" => File.join(dir, "outside")), "bash", script)
    assert !status.success?
    assert File.read(File.join(home, ".netrc")) == "temporary"
    assert File.read(File.join(state, "original.netrc")) == "original"
  end
end

check "cleanup rejects a symlinked work directory before recovering netrc" do
  cleanup_fixture do |dir, temp, home, work, state, env, script, _calls, _leaks|
    FileUtils.rm_r(work)
    victim = File.join(dir, "victim")
    FileUtils.mkdir_p(victim)
    File.symlink(victim, work)
    _, status = Open3.capture2e(env, "bash", script)
    assert !status.success?
    assert File.symlink?(work) && File.directory?(victim)
    assert File.read(File.join(home, ".netrc")) == "temporary"
    assert File.read(File.join(state, "original.netrc")) == "original"
  end
end

check "cleanup rejects a symlinked runner temp without consuming recovery state" do
  cleanup_fixture do |dir, temp, home, work, state, env, script, _calls, _leaks|
    link = File.join(dir, "runner-link")
    File.symlink(temp, link)
    _, status = Open3.capture2e(env.merge("RUNNER_TEMP" => link, "RELEASE_WORK" => File.join(link, "work")), "bash", script)
    assert !status.success?
    assert File.directory?(work)
    assert File.read(File.join(home, ".netrc")) == "temporary"
    assert File.read(File.join(state, "original.netrc")) == "original"
  end
end

check "cleanup rejects a symlinked ancestor of work without deleting outside content" do
  cleanup_fixture do |dir, temp, home, _work, state, env, script, _calls, _leaks|
    outside = File.join(dir, "outside")
    FileUtils.mkdir_p(File.join(outside, "work"))
    File.symlink(outside, File.join(temp, "linked"))
    _, status = Open3.capture2e(env.merge("RELEASE_WORK" => File.join(temp, "linked/work")), "bash", script)
    assert !status.success?
    assert File.directory?(File.join(outside, "work"))
    assert File.read(File.join(home, ".netrc")) == "temporary"
    assert File.read(File.join(state, "original.netrc")) == "original"
  end
end

check "cleanup rejects a symlinked recovery directory without consuming its backup" do
  cleanup_fixture do |dir, _temp, home, _work, state, env, script, _calls, _leaks|
    outside = File.join(dir, "outside-state")
    FileUtils.mv(state, outside)
    File.symlink(outside, state)
    _, status = Open3.capture2e(env, "bash", script)
    assert !status.success?
    assert File.read(File.join(home, ".netrc")) == "temporary"
    assert File.read(File.join(outside, "original.netrc")) == "original"
  end
end

check "cleanup rejects a symlinked journal before invoking security" do
  cleanup_fixture do |dir, _temp, home, _work, state, env, script, calls, _leaks|
    original = File.join(dir, "outside-journal")
    File.write(original, "/user/keychain\n")
    File.symlink(original, File.join(state, "original.txt"))
    _, status = Open3.capture2e(env, "bash", script)
    assert !status.success?
    assert !File.exist?(calls)
    assert File.read(File.join(home, ".netrc")) == "temporary"
  end
end

check "cleanup rejects a recorded keychain outside owned work before restoring user state" do
  cleanup_fixture do |dir, _temp, home, _work, state, env, script, calls, _leaks|
    File.write(File.join(state, "original.txt"), "/user/keychain\n")
    File.write(File.join(state, "path"), File.join(dir, "foreign.keychain-db") + "\n")
    _, status = Open3.capture2e(env, "bash", script)
    assert !status.success?
    assert !File.exist?(calls)
    assert File.read(File.join(home, ".netrc")) == "temporary"
    assert File.read(File.join(state, "original.netrc")) == "original"
  end
end

check "cleanup security children receive no signing or upload environment" do
  cleanup_fixture do |_dir, _temp, home, work, state, env, script, calls, leaks|
    keychain = File.join(work, "release.keychain-db")
    File.write(keychain, "temporary keychain")
    File.write(File.join(state, "original.txt"), "/user/login.keychain-db\n")
    File.write(File.join(state, "path"), keychain + "\n")
    sentinels = %w[ASC_KEY_CONTENT MATCH_PASSWORD TESTFLIGHT_ASC_KEY_CONTENT TESTFLIGHT_MATCH_GIT_TOKEN].to_h { |name| [name, "fixture-sentinel"] }
    _, status = Open3.capture2e(env.merge(sentinels), "bash", script)
    assert status.success?
    assert File.read(calls).include?("list-keychains -d user -s /user/login.keychain-db")
    assert !File.exist?(leaks), "security inherited credential names"
    assert File.read(File.join(home, ".netrc")) == "original"
    assert !File.exist?(work) && !File.exist?(state)
  end
end

check "cleanup restores an empty original keychain list and the existing Ruby journal path" do
  cleanup_fixture do |_dir, _temp, home, work, state, env, script, calls, _leaks|
    keychain = File.join(work, "keychain/release.keychain-db")
    FileUtils.mkdir_p(File.dirname(keychain))
    File.write(keychain, "temporary keychain")
    File.write(File.join(state, "original.txt"), "\n")
    File.write(File.join(state, "path"), keychain + "\n")
    _, status = Open3.capture2e(env, "bash", script)
    assert status.success?
    assert File.readlines(calls).first == "list-keychains -d user -s\n"
    assert File.read(File.join(home, ".netrc")) == "original"
    assert !File.exist?(work) && !File.exist?(state)
  end
end

check "cleanup restores an original netrc symlink without changing its target" do
  cleanup_fixture do |dir, _temp, home, _work, state, env, script, _calls, _leaks|
    target = File.join(dir, "original-netrc-target")
    File.write(target, "keep original credentials")
    File.unlink(File.join(state, "original.netrc"))
    # 元の .netrc がリンクなら、復旧ではリンク自体を戻して参照先を変更しない。
    File.symlink(target, File.join(state, "original.netrc"))
    _, status = Open3.capture2e(env, "bash", script)
    assert status.success?
    assert File.symlink?(File.join(home, ".netrc"))
    assert File.readlink(File.join(home, ".netrc")) == target
    assert File.read(target) == "keep original credentials"
  end
end

check "cleanup restoration failure retains recovery state while removing owned work" do
  cleanup_fixture do |dir, _temp, _home, work, state, env, script, _calls, _leaks|
    File.write(File.join(dir, "bin", "mv"), "#!/bin/sh\nexit 1\n")
    File.chmod(0o755, File.join(dir, "bin", "mv"))
    _, status = Open3.capture2e(env, "bash", script)
    assert !status.success?
    assert File.read(File.join(state, "original.netrc")) == "original"
    assert !File.exist?(work)
  end
end

check "release preserves the build error when credential-free fallback cleanup also fails" do
  cleanup_fixture do |dir, temp, home, _work, state, env, _script, _calls, leaks|
    work = File.join(temp, "release-work")
    FileUtils.mkdir_p(work)
    keychain = File.join(work, "release.keychain-db")
    File.write(keychain, "temporary keychain")
    File.write(File.join(state, "original.txt"), "/user/login.keychain-db\n")
    File.write(File.join(state, "path"), keychain + "\n")
    bin = File.join(dir, "bin")
    File.write(File.join(bin, "bundle"), "#!/bin/sh\nexit 42\n")
    File.write(File.join(bin, "mv"), "#!/bin/sh\nexit 1\n")
    File.chmod(0o755, File.join(bin, "bundle"), File.join(bin, "mv"))
    script = File.expand_path("../../legacy/ci-release.sh", __dir__)
    sentinels = { "ASC_KEY_CONTENT" => "fixture-sentinel", "MATCH_PASSWORD" => "fixture-sentinel" }
    _, status = Open3.capture2e(env.merge(sentinels).merge("GITHUB_ACTIONS" => "true"), "bash", script, home)
    assert status.exitstatus == 42
    assert !File.exist?(leaks), "release fallback cleanup inherited credentials"
    assert File.read(File.join(state, "original.netrc")) == "original"
  end
end

finish
