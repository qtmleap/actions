# frozen_string_literal: true
require "json"
require "digest"
require "fileutils"
require "tmpdir"
require "open3"
require_relative "environment"

module SharedCI
  class MacDMG
    class Error < StandardError; end
    class Runner
      def call(env, argv)
        output, status = Open3.capture2e(env, *argv, unsetenv_others: true)
        # Native error output may contain credential paths or provider details.
        raise Error, "Native DMG command failed: #{argv.first}" unless status.success?
        output
      end
    end
    def initialize(runner: Runner.new)
      @runner = runner
    end
    def command(*argv)
      @runner.call(Environment.child, argv)
    rescue StandardError
      raise Error, "Native DMG lifecycle failed: #{argv.first}"
    end
    def call(app:, dmg:, team:, identity:, volume:, app_name:, checksum_path:, key_id:, issuer:, key_path: nil, key_content: nil)
      raise Error, "Invalid Developer ID/team" unless team.to_s.match?(/\A[A-Z0-9]{10}\z/) &&
        identity.to_s.start_with?("Developer ID Application: ") && identity.end_with?("(#{team})")
      raise Error, "Invalid app name" unless app_name.to_s.match?(/\A[^\/\r\n]+\.app\z/) && app_name != "Applications.app"
      raise Error, "Invalid volume" unless volume.is_a?(String) && !volume.empty? && !volume.match?(/[\r\n]/)
      raise Error, "Invalid ASC identity" unless key_id.to_s.match?(/\A[A-Z0-9]{10}\z/) && issuer.to_s.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      raise Error, "Supply exactly one ASC key source" unless (!!key_path) ^ (!!key_content)
      app = File.realpath(app)
      dmg, checksum_path = [dmg, checksum_path].map do |path|
        expanded = File.expand_path(path)
        File.join(File.realpath(File.dirname(expanded)), File.basename(expanded))
      end
      raise Error, "DMG output must end in .dmg" unless dmg.end_with?(".dmg")
      raise Error, "App directory missing" unless File.directory?(app)
      raise Error, "Outputs must be new and outside app" if [dmg, checksum_path].any? { |p| File.exist?(p) || File.symlink?(p) || p == app || p.start_with?(app + "/") } || dmg == checksum_path
      Dir.mktmpdir("shared-dmg-") do |temp|
        File.chmod(0o700, temp)
        key = key_path && File.realpath(key_path)
        if key_content
          raise Error, "Empty private key content" unless key_content.is_a?(String) && !key_content.empty?
          key = File.join(temp, "asc-key")
          File.open(key, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(key_content) }
        end
        raise Error, "Private key file missing" unless File.file?(key)
        identities = command("security", "find-identity", "-v", "-p", "codesigning")
        raise Error, "Developer ID identity unavailable" unless identities.include?("\"#{identity}\"")
        verify_identity(app, team, identity)
        command("codesign", "--verify", "--deep", "--strict", "--verbose=2", app)
        zip = File.join(temp, "app.zip")
        command("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, zip)
        notarize(zip, key, key_id, issuer)
        staple_assess(app, :app)
        stage = File.join(temp, "stage")
        FileUtils.mkdir_p(stage)
        command("ditto", app, File.join(stage, app_name))
        File.symlink("/Applications", File.join(stage, "Applications"))
        command("hdiutil", "create", "-volname", volume, "-srcfolder", stage, "-format", "UDZO", dmg)
        command("codesign", "--force", "--timestamp", "--sign", identity, dmg)
        verify_identity(dmg, team, identity)
        command("codesign", "--verify", "--strict", "--verbose=2", dmg)
        notarize(dmg, key, key_id, issuer)
        staple_assess(dmg, :dmg)
        command("codesign", "--verify", "--strict", "--verbose=2", dmg)
        command("hdiutil", "verify", dmg)
        digest = Digest::SHA256.file(dmg).hexdigest
        File.open(checksum_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write("#{digest}  #{File.basename(dmg)}\n")
        end
        digest
      end
    rescue Error
      raise
    rescue StandardError
      raise Error, "DMG lifecycle failed"
    end
    private
    def verify_identity(path, team, identity)
      details = command("codesign", "--display", "--verbose=4", path)
      raise Error, "Signed artifact Developer ID/team mismatch" unless details.lines.map(&:strip).include?("TeamIdentifier=#{team}") &&
        details.lines.map(&:strip).include?("Authority=#{identity}")
    end
    def notarize(path, key, key_id, issuer)
      result = JSON.parse(command("xcrun", "notarytool", "submit", path, "--key", key, "--key-id", key_id,
                                  "--issuer", issuer, "--wait", "--output-format", "json"))
      raise Error, "Notarization was not Accepted" unless result.is_a?(Hash) && result["status"] == "Accepted"
    rescue JSON::ParserError
      raise Error, "Malformed notarization result"
    end
    def staple_assess(path, kind)
      command("xcrun", "stapler", "staple", path)
      command("xcrun", "stapler", "validate", path)
      if kind == :app
        command("spctl", "--assess", "--type", "execute", "--verbose=2", path)
      else
        command("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", path)
      end
    end
  end
end
