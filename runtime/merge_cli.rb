require_relative "merge_verifier"
begin
  config_path, root = ARGV
  raise SharedCI::MergeVerifier::Error, "Usage: merge_cli.rb config.json app-root" unless ARGV.length == 2
  result = SharedCI::MergeVerifier.new(config: JSON.parse(File.read(config_path)), env: ENV.to_h,
    event: JSON.parse(File.read(ENV.fetch("GITHUB_EVENT_PATH"))),
    api: SharedCI::MergeVerifier::Api.new(token: ENV["GITHUB_TOKEN"]),
    git: SharedCI::MergeVerifier::Git.new(File.realpath(root))).call
  SharedCI::MergeVerifier.write_output(ENV.fetch("GITHUB_OUTPUT"), **result)
rescue SharedCI::MergeVerifier::Error, JSON::ParserError, KeyError, SystemCallError
  warn "Merge verification failed"
  exit 1
end
