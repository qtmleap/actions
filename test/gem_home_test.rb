require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rubygems/package"
require "rbconfig"
require "open3"
require "json"
require_relative "../runtime/environment"

class GemHomeTest < Minitest::Test
  def test_local_gem_install_uses_writable_owned_home_without_network
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      home = File.join(dir, "output/gems")
      FileUtils.mkdir_p([home, File.join(dir, "lib")])
      File.write(File.join(home, ".probe"), "writable")
      File.write(File.join(dir, "lib/shared_ci_fixture.rb"), "SHARED_CI_FIXTURE = true\n")
      spec = Gem::Specification.new do |gem|
        gem.name = "shared_ci_fixture"
        gem.version = "1.0.0"
        gem.summary = "Offline writable gem home regression"
        gem.authors = ["Shared CI tests"]
        gem.files = ["lib/shared_ci_fixture.rb"]
      end
      archive = Dir.chdir(dir) { Gem::Package.build(spec) }
      env = SharedCI::Environment.child(ENV.to_h.merge("GEM_HOME" => home, "GEM_PATH" => "#{home}:#{Gem.default_dir}",
        "PATH" => "#{home}/bin:#{ENV.fetch('PATH')}"))
      output, status = Open3.capture2e(env, RbConfig.ruby, "-S", "gem", "install",
        File.join(dir, archive), "--local", "--no-document", "--ignore-dependencies", unsetenv_others: true)
      assert status.success?, output
      assert File.file?(File.join(home, "gems/shared_ci_fixture-1.0.0/lib/shared_ci_fixture.rb"))
      output, status = Open3.capture2e(env, RbConfig.ruby, "-rjson", "-e", <<~RUBY, unsetenv_others: true)
        require "shared_ci_fixture"
        require "minitest"
        puts JSON.generate(home: Gem.dir, paths: Gem.path, fixture: Gem.loaded_specs.fetch("shared_ci_fixture").full_gem_path,
                           minitest: Gem.loaded_specs.fetch("minitest").full_gem_path)
      RUBY
      assert status.success?, output
      actual = JSON.parse(output)
      assert_equal home, actual.fetch("home")
      assert_includes actual.fetch("paths"), Gem.default_dir
      assert actual.fetch("fixture").start_with?(home + "/gems/")
      assert actual.fetch("minitest").start_with?(Gem.default_dir + "/gems/")
    end
  end
end
