require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "digest"
require_relative "../runtime/mac_dmg"

class MacDMGTest < Minitest::Test
  def setup
    @dir = File.realpath(Dir.mktmpdir)
    @app = File.join(@dir, "Fixture.app")
    FileUtils.mkdir_p(@app)
    @dmg = File.join(@dir, "out.dmg")
    @commands = []
    @keys = []
    @reject = false
    @runner = lambda do |env, argv|
      @commands << argv
      assert env.key?("TESTFLIGHT_ASC_KEY_CONTENT")
      assert_nil env["TESTFLIGHT_ASC_KEY_CONTENT"]
      if argv.include?("--key")
        key = argv[argv.index("--key") + 1]
        @keys << key
        assert File.file?(key)
        assert_equal 0o600, File.stat(key).mode & 0o777
      end
      if argv.first == "hdiutil" && argv[1] == "create"
        assert_equal "/Applications", File.readlink(File.join(argv[argv.index("-srcfolder") + 1], "Applications"))
        File.write(@dmg, "initial")
      end
      File.write(@dmg, "final stapled bytes") if argv.include?("staple") && argv.last == @dmg
      if argv.include?("find-identity") then '1) ABC "Developer ID Application: Fixture (ABCDEFGHIJ)"'
      elsif argv.include?("--display") then "Authority=Developer ID Application: Fixture (ABCDEFGHIJ)\nTeamIdentifier=ABCDEFGHIJ\n"
      elsif argv.include?("notarytool") then JSON.generate({ "status" => @reject ? "Invalid" : "Accepted" })
      else ""
      end
    end
    @old = ENV["TESTFLIGHT_ASC_KEY_CONTENT"]
    ENV["TESTFLIGHT_ASC_KEY_CONTENT"] = "sentinel"
  end
  def teardown
    @old ? ENV["TESTFLIGHT_ASC_KEY_CONTENT"] = @old : ENV.delete("TESTFLIGHT_ASC_KEY_CONTENT")
    FileUtils.remove_entry(@dir)
  end
  def call
    SharedCI::MacDMG.new(runner: @runner).call(app: @app, dmg: @dmg, team: "ABCDEFGHIJ",
      identity: "Developer ID Application: Fixture (ABCDEFGHIJ)", volume: "Fixture", app_name: "Fixture.app",
      checksum_path: File.join(@dir, "checksum.sha256"), key_id: "ABCDEFGHIJ", issuer: "11111111-1111-1111-1111-111111111111",
      key_content: "private key test content")
  end
  def test_lifecycle_and_final_checksum
    assert_equal Digest::SHA256.hexdigest("final stapled bytes"), call
    assert_equal 2, @commands.count { |c| c.include?("notarytool") }
    assert_equal 2, @commands.count { |c| c.include?("staple") }
    assert_equal ["hdiutil", "verify", @dmg], @commands.last
    assert_equal "#{Digest::SHA256.hexdigest('final stapled bytes')}  out.dmg\n", File.read(File.join(@dir, "checksum.sha256"))
    refute_includes @commands.find { |c| c.first == "hdiutil" && c[1] == "create" }, "-ov"
    staple = @commands.index { |c| c.include?("staple") && c.last == @dmg }
    assert staple < @commands.length - 1
    assert @keys.none? { |path| File.exist?(path) }
    assert @commands.none? { |c| c.join.include?("private key test content") }
  end
  def test_rejected_notarization_stops_before_dmg_and_removes_key
    @reject = true
    assert_raises(SharedCI::MacDMG::Error) { call }
    refute File.exist?(@dmg)
    refute File.exist?(File.join(@dir, "checksum.sha256"))
    assert @keys.none? { |path| File.exist?(path) }
  end
  def test_verify_failure_does_not_write_checksum
    real = @runner
    @runner = ->(env, argv) { real.call(env, argv); raise "bad image" if argv.first == "hdiutil" && argv[1] == "verify" }
    assert_raises(SharedCI::MacDMG::Error) { call }
    refute File.exist?(File.join(@dir, "checksum.sha256"))
    assert @keys.none? { |path| File.exist?(path) }
  end
  def test_existing_dmg_is_never_overwritten
    File.write(@dmg, "existing")
    assert_raises(SharedCI::MacDMG::Error) { call }
    assert_equal "existing", File.read(@dmg)
    assert_empty @commands
  end
  def test_command_failure_removes_temporary_key
    real = @runner
    @runner = ->(env, argv) { real.call(env, argv); raise "failure" if argv.include?("notarytool") }
    assert_raises(SharedCI::MacDMG::Error) { call }
    assert @keys.none? { |path| File.exist?(path) }
  end
end
