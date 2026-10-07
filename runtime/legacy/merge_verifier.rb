# frozen_string_literal: true
require_relative "deployment_policy"
require_relative "../compatibility"
MergeVerifier = SharedCI.merge_wrapper(
  error_class: DeploymentPolicy::Error,
  config: { repository: DeploymentPolicy::REPOSITORY, branches: DeploymentPolicy::BRANCHES,
            workflow: DeploymentPolicy::WORKFLOW, required_checks: ReleaseConfig::REQUIRED,
            record_only_paths: [DeploymentPolicy::SHIPPED_RECORD] }
)
