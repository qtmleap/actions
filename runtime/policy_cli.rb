require_relative "legacy_loader"
begin
  raise ArgumentError, "Usage: policy_cli.rb app-root" unless ARGV.length == 1
  root = File.realpath(ARGV.first)
  SharedCI.load_legacy("deployment_policy", app_root: root)
  puts "CI deployment target: #{DeploymentPolicy.authorize!(lane: :beta, repo_root: root)}"
rescue StandardError
  warn "Deployment policy denied"
  exit 1
end
