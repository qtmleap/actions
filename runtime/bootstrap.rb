# frozen_string_literal: true
require "digest"
require "json"
require "yaml"
require "find"

module SharedCI
  module Bootstrap
    class Error < StandardError; end
    SHA = /\A[0-9a-f]{40}\z/
    DIGEST = /\A[0-9a-f]{64}\z/
    module_function
    def app_root!(env = ENV)
      workspace = File.realpath(env.fetch("GITHUB_WORKSPACE"))
      relative = env.fetch("SHARED_REPO_ROOT", ".")
      raise Error, "Invalid repo-root" if relative.empty? || relative.start_with?("/") || relative.match?(/[\r\n\x00]/) || relative.split("/").include?("..")
      candidate = File.join(workspace, relative)
      # Canonicalize the workspace (including macOS /var), not caller symlinks.
      cursor = workspace
      relative.split("/").each do |part|
        cursor = File.join(cursor, part)
        raise Error, "repo-root symlink rejected" if File.symlink?(cursor)
      end
      app = File.realpath(candidate)
      raise Error, "repo-root outside workspace" unless app == workspace || app.start_with?(workspace + "/")
      raise Error, "repo-root is not a directory" unless File.directory?(app)
      app
    rescue SystemCallError => error
      raise Error, "Cannot resolve repo-root: #{error.class}"
    end
    def lock!(app_root)
      lock = JSON.parse(File.read(File.join(app_root, ".github/shared-actions.lock.json")))
      raise Error, "Invalid lock schema" unless lock.is_a?(Hash) && lock.keys.sort == %w[revision runtime_files]
      revision, files = lock.values_at("revision", "runtime_files")
      raise Error, "Invalid revision" unless revision.is_a?(String) && revision.match?(SHA)
      raise Error, "Invalid digest list" unless files.is_a?(Hash) && !files.empty? && files.all? do |path, digest|
        path.is_a?(String) && path.match?(%r{\Aruntime/[A-Za-z0-9_./-]+\z}) &&
          path.split("/").none? { |part| %w[. ..].include?(part) } && digest.is_a?(String) && digest.match?(DIGEST)
      end
      lock
    rescue JSON::ParserError, SystemCallError => error
      raise Error, "Cannot read shared runtime lock: #{error.class}"
    end
    def coherence!(app_root, revision)
      refs = []
      walk = lambda do |value|
        case value
        when Hash
          value.each do |key, entry|
            if key == "uses" && entry.is_a?(String) && entry.downcase.start_with?("qtmleap/actions/")
              refs << entry
            end
            walk.call(entry)
          end
        when Array then value.each { |entry| walk.call(entry) }
        end
      end
      Dir.glob(File.join(app_root, ".github/{workflows,actions}/**/*.{yml,yaml}")).each do |path|
        walk.call(YAML.safe_load(File.read(path), permitted_classes: [], aliases: false))
      end
      raise Error, "No shared action references" if refs.empty?
      raise Error, "YAML/lock revision mismatch" unless refs.all? { |ref| ref.match?(%r{\Aqtmleap/actions/(?:actions/[a-z-]+|\.github/workflows/backmerge\.ya?ml)@#{revision}\z}) }
      true
    rescue Psych::Exception
      raise Error, "Malformed workflow YAML"
    end
    def verify!(root:, app_root:, revision:, allow_test_revision: false)
      lock = lock!(app_root)
      raise Error, "Expected revision disagrees with lock" unless revision == lock.fetch("revision")
      raise Error, "Zero revision is test-only" if revision == "0" * 40 && !allow_test_revision
      root, app = File.realpath(root), File.realpath(app_root)
      raise Error, "Runtime must be outside source" if root == app || root.start_with?(app + "/")
      files = []
      Find.find(File.join(root, "runtime")) do |path|
        raise Error, "Runtime symlink rejected" if File.symlink?(path)
        raise Error, "Special runtime file rejected" unless File.directory?(path) || File.file?(path)
        files << path.delete_prefix(root + "/") if File.file?(path)
      end
      raise Error, "Runtime file list mismatch" unless files.sort == lock.fetch("runtime_files").keys.sort
      lock.fetch("runtime_files").each do |path, expected|
        raise Error, "Runtime digest mismatch: #{path}" unless Digest::SHA256.file(File.join(root, path)).hexdigest == expected
      end
      coherence!(app, revision)
      root
    rescue SystemCallError => error
      raise Error, "Cannot verify shared runtime: #{error.class}"
    end
    def export!(root:, app_root:, revision:)
      verified = verify!(root: root, app_root: app_root, revision: revision)
      ENV["QTMLEAP_ACTIONS_ROOT"] = verified
      ENV["QTMLEAP_ACTIONS_REVISION"] = revision
      verified
    end
  end
end
