# frozen_string_literal: true
require "json"
require "fileutils"
module SharedCI
  module Records
    class Error < StandardError; end
    MAX_BYTES = 1_048_576
    # Receipts are data, never arbitrary recovery state or private key envelopes.
    KEYS = %w[sha source_sha merge_sha pr pr_number build build_number upload_result version platform uploaded_at upload_confirmed
              app_identifier bundle_id file filename sha256 checksum status receipt_id run_id run_attempt
              artifact_id notarization_id release_id tag url size created_at confirmed_at core_sha timestamp].freeze
    module_function
    def preserve!(pattern:, destination:, expected_source_sha:, missing: "ignore")
      raise Error, "Invalid expected source SHA" unless expected_source_sha.is_a?(String) && expected_source_sha.match?(/\A[0-9a-f]{40}\z/)
      raise Error, "Invalid missing behavior" unless %w[ignore warn error].include?(missing)
      files = Dir.glob(pattern).sort
      if files.empty?
        raise Error, "Receipt missing" if missing == "error"
        warn "::warning::Receipt missing" if missing == "warn"
        return false
      end
      raise Error, "Too many receipts" if files.length > 20
      parsed = files.map do |path|
        raise Error, "Only regular JSON receipts allowed" unless path.end_with?(".json") && File.file?(path) && !File.symlink?(path) && File.realpath(path) == File.expand_path(path)
        raise Error, "Receipt too large" if File.size(path) > MAX_BYTES
        data = JSON.parse(File.read(path))
        raise Error, "Receipt must be an object" unless data.is_a?(Hash) && !data.empty?
        raise Error, "Unknown receipt field" unless (data.keys - KEYS).empty?
        sources = data.values_at(*%w[sha source_sha merge_sha]).compact
        raise Error, "Receipt source mismatch" if sources.empty? || sources.any? { |sha| sha != expected_source_sha }
        raise Error, "Invalid receipt source" if %w[sha source_sha merge_sha].any? { |key| data.key?(key) && data[key] != expected_source_sha }
        raise Error, "Receipt values must be scalar" unless data.values.all? { |v| v.nil? || v == true || v == false || v.is_a?(Numeric) || (v.is_a?(String) && v.bytesize <= 4096 && !v.match?(/-----BEGIN|PRIVATE KEY|[\x00-\x08]/)) }
        [File.basename(path), JSON.pretty_generate(data) + "\n"]
      end
      raise Error, "Duplicate receipt filenames" unless parsed.map(&:first).uniq.length == parsed.length
      raise Error, "Snapshot destination already exists" if File.exist?(destination)
      FileUtils.mkdir_p(destination, mode: 0o700)
      parsed.each { |name, body| File.open(File.join(destination, name), File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(body) } }
      true
    rescue JSON::ParserError, SystemCallError
      raise Error, "Cannot read JSON receipt"
    end
  end
end
