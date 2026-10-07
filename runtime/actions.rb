# frozen_string_literal: true
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "securerandom"
require_relative "bootstrap"
require_relative "environment"
require_relative "records"
module SharedCI
  module Actions
    module_function
    def inside_path(root, relative)
      raise ArgumentError, "Expected repository-relative path" if relative.empty? || relative.start_with?("/") || relative.split("/").include?("..")
      path = File.realpath(File.join(root, relative))
      raise ArgumentError, "Path outside source" unless path == root || path.start_with?(root + "/")
      path
    end
    def execute(operation, env = ENV)
      app = Bootstrap.app_root!(env)
      root = File.realpath(env.fetch("SHARED_ACTION_ROOT"))
      revision = Bootstrap.lock!(app).fetch("revision")
      expected = env["QTMLEAP_ACTIONS_REVISION"]
      raise Bootstrap::Error, "Expected revision mismatch" if expected && expected != revision
      Bootstrap.export!(root: root, app_root: app, revision: revision)
      env = env.to_h.merge("QTMLEAP_ACTIONS_ROOT" => root, "QTMLEAP_ACTIONS_REVISION" => revision)
      working = inside_path(app, env.fetch("SHARED_WORKING_DIRECTORY", "."))
      case operation
      when "ruby-check"
        if env["GEM_HOME"] == "/output/gems"
          raise "Pinned Ruby image gem path changed" unless Gem.default_dir == "/usr/local/lib/ruby/gems/3.4.0" && Gem.path.include?(Gem.default_dir)
        end
        command = env.fetch("SHARED_COMMAND")
        raise ArgumentError, "Empty command" if command.strip.empty?
        system(Environment.child(env), "bash", "-euc", command, chdir: working, unsetenv_others: true) || raise("Ruby check failed")
      when "verify-merge", "run-adapter"
        adapter = inside_path(app, env.fetch("SHARED_ADAPTER"))
        raise ArgumentError, "Adapter must be Ruby" unless File.file?(adapter) && adapter.end_with?(".rb")
        args = []
        child = Environment.child(env)
        if operation == "run-adapter"
          op = env.fetch("SHARED_OPERATION")
          raise ArgumentError, "Invalid adapter operation" unless op.match?(/\A[a-z][a-z0-9-]{0,63}\z/)
          args = JSON.parse(env.fetch("SHARED_ARGV_JSON", "[]"))
          raise ArgumentError, "Invalid JSON argv" unless args.is_a?(Array) && args.length <= 100 && args.all? { |a| a.is_a?(String) && a.bytesize <= 4096 && !a.include?("\0") }
          args.unshift(op)
          # Adapters receive step-scoped credentials in their Ruby parent. They MUST
          # use Environment.child / legacy policy for compilation and cleanup children.
          child = op == "cleanup" ? Environment.child(env) : env.to_h.dup
          child.merge!("QTMLEAP_ACTIONS_ROOT" => root, "QTMLEAP_ACTIONS_REVISION" => revision)
        else
          child["GITHUB_TOKEN"] = env.fetch("SHARED_GITHUB_TOKEN")
        end
        child.merge!("SHARED_GITHUB_TOKEN" => nil, "SHARED_ARGV_JSON" => nil)
        system(child, RbConfig.ruby, adapter, *args, chdir: working, unsetenv_others: true) || raise("Adapter failed")
        if operation == "verify-merge"
          lines = File.readlines(env.fetch("GITHUB_OUTPUT"), chomp: true)
          raise ArgumentError, "Malformed verifier adapter output" unless lines.length == 2 &&
            lines.count { |line| line == "sha=#{env.fetch('GITHUB_SHA')}" && line.match?(/\Asha=[0-9a-f]{40}\z/) } == 1 &&
            lines.count { |line| line.match?(/\Apr_number=[1-9]\d{0,9}\z/) } == 1
        end
      when "release-record"
        temp = File.realpath(env.fetch("RUNNER_TEMP"))
        raise ArgumentError, "Snapshot must be outside source" if temp == app || temp.start_with?(app + "/")
        destination = File.join(temp, "shared-receipts-#{SecureRandom.hex(16)}")
        pattern = env.fetch("SHARED_RECORD_PATH")
        pattern = File.join(working, pattern) unless pattern.start_with?("/")
        found = Records.preserve!(pattern: pattern, destination: destination,
          expected_source_sha: env.fetch("SHARED_EXPECTED_SOURCE_SHA") { env.fetch("GITHUB_SHA") },
          missing: env.fetch("SHARED_MISSING", "ignore"))
        File.open(env.fetch("GITHUB_OUTPUT"), "a") { |f| f.write("found=#{found}\npath=#{destination}\n") }
      else raise ArgumentError, "Unknown action operation"
      end
      if env["GITHUB_ENV"]
        exported = env.fetch("SHARED_HOST_ROOT", root)
        raise ArgumentError, "Unsafe root" if exported.match?(/[\r\n]/)
        File.open(env.fetch("GITHUB_ENV"), "a") { |f| f.write("QTMLEAP_ACTIONS_ROOT=#{exported}\nQTMLEAP_ACTIONS_REVISION=#{revision}\n") }
      end
    end
  end
end
if __FILE__ == $PROGRAM_NAME
  begin
    SharedCI::Actions.execute(ARGV.fetch(0))
  rescue StandardError
    warn "::error::Shared action failed; verify inputs, lock, runtime and adapter"
    exit 1
  end
end
