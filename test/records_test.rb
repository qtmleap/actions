require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../runtime/records"
class RecordsTest < Minitest::Test
  def setup
    @dir = File.realpath(Dir.mktmpdir)
    @receipt = File.join(@dir, "uploaded.json")
    @dest = File.join(@dir, "snapshot")
  end
  def teardown = FileUtils.remove_entry(@dir)
  def preserve = SharedCI::Records.preserve!(pattern: @receipt, destination: @dest, expected_source_sha: "a" * 40)
  def test_cleanup_failure_does_not_remove_confirmed_receipt
    File.write(@receipt, JSON.generate({ source_sha: "a" * 40, build_number: 12, upload_result: "uploaded" }))
    begin
      raise "cleanup restoration failed"
    rescue RuntimeError
      # Caller always-record step is independent of cleanup status.
      assert preserve
    end
    assert_equal "uploaded", JSON.parse(File.read(File.join(@dest, "uploaded.json")))["upload_result"]
    assert File.exist?(@receipt)
  end
  def test_first_platform_receipt_survives_second_platform_failure
    File.write(@receipt, JSON.generate({ platform: "tvOS", upload_result: "uploaded", source_sha: "a" * 40 }))
    begin
      raise "iOS upload failed"
    rescue RuntimeError
      assert SharedCI::Records.preserve!(pattern: File.join(@dir, "*.json"), destination: @dest, expected_source_sha: "a" * 40)
    end
    assert_equal "tvOS", JSON.parse(File.read(File.join(@dest, "uploaded.json")))["platform"]
    assert_equal ["uploaded.json"], Dir.children(@dest)
  end
  def test_rejects_keys_binary_malformed_and_oversized_records
    ["not JSON", JSON.generate({ private_key: "secret" }), "x" * (SharedCI::Records::MAX_BYTES + 1), "[]"].each do |text|
      File.write(@receipt, text)
      assert_raises(SharedCI::Records::Error) { preserve }
      refute File.exist?(@dest)
    end
  end
  def test_actual_connect_qualia_kotatsu_receipt_schemas
    # Scalar field shapes written by the distribution adapters, not generic mocks.
    receipts = [
      { source_sha: "a" * 40, core_sha: "b" * 40, build_number: 120, timestamp: "2026-10-07T00:00:00Z", upload_result: "draft", sha256: "c" * 64, filename: "Connect.dmg" },
      { sha: "a" * 40, build_number: "121", timestamp: "2026-10-07T00:00:00Z", upload_result: "uploaded", checksum: "c" * 64, file: "Qualia.dmg" },
      { merge_sha: "a" * 40, source_sha: "a" * 40, platform: "tvOS", build_number: 122, upload_result: "uploaded", uploaded_at: "2026-10-07T00:00:00Z" }
    ]
    receipts.each do |receipt|
      File.write(@receipt, JSON.generate(receipt))
      assert preserve
      assert_equal receipt.transform_keys(&:to_s), JSON.parse(File.read(File.join(@dest, "uploaded.json")))
      FileUtils.remove_entry(@dest)
    end
  end
  def test_stale_musicfin_record_and_mixed_source_fields_are_not_preserved
    [
      { sha: "b" * 40, build_number: 1, upload_result: "uploaded" },
      { source_sha: "a" * 40, merge_sha: "b" * 40 },
      { source_sha: "a" * 40, sha: nil },
      { build_number: 1, upload_result: "uploaded" }
    ].each do |receipt|
      File.write(@receipt, JSON.generate(receipt))
      assert_raises(SharedCI::Records::Error) { preserve }
      refute File.exist?(@dest)
    end
  end
  def test_parent_symlink_remains_rejected
    actual = File.join(@dir, "actual")
    FileUtils.mkdir_p(actual)
    File.write(File.join(actual, "record.json"), JSON.generate({ sha: "a" * 40 }))
    File.symlink(actual, File.join(@dir, "alias"))
    assert_raises(SharedCI::Records::Error) do
      SharedCI::Records.preserve!(pattern: File.join(@dir, "alias/record.json"), destination: @dest, expected_source_sha: "a" * 40)
    end
  end
  def test_symlink_and_missing_behavior
    File.write(File.join(@dir, "key"), "private")
    File.symlink(File.join(@dir, "key"), @receipt)
    assert_raises(SharedCI::Records::Error) { preserve }
    File.unlink(@receipt)
    refute preserve
    assert_raises(SharedCI::Records::Error) { SharedCI::Records.preserve!(pattern: @receipt, destination: @dest, expected_source_sha: "a" * 40, missing: "error") }
  end
end
