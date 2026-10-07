require "yaml"
require "open3"
contracts = {
  "ruby-check" => %w[command working-directory],
  "verify-merge" => %w[adapter github-token working-directory],
  "apple-toolchain" => %w[xcode-version developer-dir],
  "setup-ruby" => %w[ruby-version working-directory],
  "repository-token" => %w[client-id private-key repository],
  "run-adapter" => %w[adapter operation argv-json working-directory],
  "release-record" => %w[name path if-no-files-found]
}
contracts.each do |name, inputs|
  action = YAML.safe_load(File.read("actions/#{name}/action.yml"), aliases: false)
  expected = ["repo-root", *(name == "release-record" ? ["expected-source-sha"] : []), *inputs]
  abort "Input contract changed: #{name}" unless action.fetch("inputs").keys == expected
  abort "Missing nested checkout input" unless action.dig("runs", "steps").first.dig("env", "SHARED_REPO_ROOT") == '${{ inputs.repo-root }}'
  abort "Not composite: #{name}" unless action.dig("runs", "using") == "composite"
  action.fetch("runs").fetch("steps").each do |step|
    if step["uses"]
      abort "Unpinned nested action" unless step["uses"].match?(/@[0-9a-f]{40}\z/)
      abort "Mixed run/uses" if step["run"]
    else
      abort "Unsupported shell" unless step["shell"] == "bash"
      _, status = Open3.capture2e("bash", "-n", stdin_data: step.fetch("run"))
      abort "Bad composite shell syntax: #{name}" unless status.success?
    end
  end
end
records = YAML.safe_load(File.read("actions/release-record/action.yml"), aliases: false)
steps = records.fetch("runs").fetch("steps")
abort "Record validation is not always-run" unless steps.first["if"] == "always()"
abort "Upload bypasses validation" unless steps.last["if"].include?("always()") && steps.last["if"].include?("steps.receipts.outcome == 'success'") && steps.last["if"].include?("steps.receipts.outputs.found == 'true'")
adapter = YAML.safe_load(File.read("actions/run-adapter/action.yml"), aliases: false)
abort "Cleanup cannot survive prior failure" unless adapter.dig("runs", "steps").first["if"] == "always()"
abort "Record source binding missing" unless records.dig("inputs", "expected-source-sha", "default") == '${{ github.sha }}' && steps.first.dig("env", "SHARED_EXPECTED_SOURCE_SHA") == '${{ inputs.expected-source-sha }}'
abort "Unexpected artifact runtime pin" unless steps.last["uses"] == "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"
workflow = YAML.safe_load(File.read(".github/workflows/shared-runtime.yaml"), aliases: false)
job = workflow.fetch("jobs").fetch("shared-tests")
abort "Linux runner contract changed" unless job["runs-on"] == %w[self-hosted Linux X64 ubuntu-latest docker]
abort "Fork PR self-hosted guard missing" unless job["if"] == "github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository"
puts "Composite YAML/input/pin/shell/always-record/nested-root/runner contracts passed"
