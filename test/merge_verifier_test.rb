require "minitest/autorun"
require_relative "../runtime/merge_verifier"

class MergeVerifierTest < Minitest::Test
  S = "a" * 40
  B = "b" * 40
  H = "c" * 40
  def setup
    @config = { repository: "qtmleap/App", branches: %w[develop master], workflow: ".github/workflows/testflight.yaml",
                required_checks: { ".github/workflows/ci.yaml" => ["Policy"] }, record_only_paths: ["release/receipt.json"] }
    @env = { "GITHUB_ACTIONS" => "true", "RUNNER_ENVIRONMENT" => "self-hosted", "GITHUB_EVENT_NAME" => "push",
             "GITHUB_SHA" => S, "GITHUB_REF" => "refs/heads/develop", "GITHUB_REPOSITORY" => "qtmleap/App",
             "GITHUB_RUN_ATTEMPT" => "1", "GITHUB_WORKFLOW_REF" => "qtmleap/App/.github/workflows/testflight.yaml@refs/heads/develop" }
    @event = { "ref" => @env["GITHUB_REF"], "before" => B, "after" => S, "created" => false, "deleted" => false,
               "forced" => false, "repository" => { "full_name" => "qtmleap/App" } }
    @run = { "id" => 12, "run_number" => 2, "run_attempt" => 2, "check_suite_id" => 42,
             "path" => ".github/workflows/ci.yaml", "event" => "pull_request", "head_sha" => H, "head_branch" => "feature",
             "head_repository" => { "full_name" => "qtmleap/App" }, "status" => "completed", "conclusion" => "success" }
    @check = { "id" => 33, "name" => "Policy", "head_sha" => H, "app" => { "slug" => "github-actions" },
               "check_suite" => { "id" => 42 }, "status" => "completed", "conclusion" => "success" }
    @jobs = [{ "name" => "Policy", "check_run_url" => "https://api.github.com/repos/qtmleap/App/check-runs/33",
               "status" => "completed", "conclusion" => "success" }]
    @pull = { "number" => 7, "merged" => true, "merge_commit_sha" => S,
              "base" => { "ref" => "develop", "repo" => { "full_name" => "qtmleap/App" } },
              "head" => { "sha" => H, "ref" => "feature", "repo" => { "full_name" => "qtmleap/App" } } }
    @paths = "App.swift\0"
    @parents = "#{S} #{B} #{H}"
    @requests = []
  end

  def verifier
    test = self
    api = Object.new
    api.define_singleton_method(:get) { |path| test.response(path) }
    git = Object.new
    git.define_singleton_method(:call) { |*args| test.git_response(args) }
    SharedCI::MergeVerifier.new(config: @config, env: @env, event: @event, api: api, git: git, attempts: 1)
  end

  def git_response(args)
    case args.first
    when "rev-list" then @parents
    when "diff" then @paths
    else raise "unexpected git request #{args.inspect}"
    end
  end

  def response(path)
    @requests << path
    return @overrides.fetch(path) if @overrides && @overrides.key?(path)
    case path
    when "repos/qtmleap/App/commits/#{S}/pulls?per_page=100&page=1" then [{ "number" => 7 }]
    when "repos/qtmleap/App/pulls/7" then @pull
    when "repos/qtmleap/App/actions/runs?head_sha=#{H}&per_page=100&page=1" then { "workflow_runs" => [@run] }
    when "repos/qtmleap/App/commits/#{H}/check-runs?per_page=100&filter=latest&page=1" then { "check_runs" => [@check] }
    when "repos/qtmleap/App/actions/runs/12/attempts/2/jobs?per_page=100&page=1" then { "jobs" => @jobs }
    when "repos/qtmleap/App/branches/develop" then { "commit" => { "sha" => S } }
    else raise "unexpected API request #{path}"
    end
  end

  def test_exact_attempt_authorizes
    assert_equal({ sha: S, pr_number: 7 }, verifier.call)
    assert_includes @requests, "repos/qtmleap/App/actions/runs/12/attempts/2/jobs?per_page=100&page=1"
  end
  def test_previous_attempt_check_cannot_authorize
    @jobs.first["check_run_url"] = "https://api.github.com/repos/qtmleap/App/check-runs/32"
    assert_raises(SharedCI::MergeVerifier::Error) { verifier.call }
  end
  def test_failed_job_cannot_be_replaced_by_successful_check
    @jobs.first["conclusion"] = "failure"
    assert_raises(SharedCI::MergeVerifier::Error) { verifier.call }
  end
  def test_forged_check_and_malformed_jobs
    @check["app"]["slug"] = "untrusted"
    assert_raises(SharedCI::MergeVerifier::Error) { verifier.call }
    @jobs = ["malformed"]
    assert_raises(SharedCI::MergeVerifier::Error) { verifier.call }
  end
  def test_latest_failed_attempt_not_old_success
    @run["conclusion"] = "failure"
    assert_raises(SharedCI::MergeVerifier::Error) { verifier.call }
  end
  def test_record_only_and_direct_push
    @paths = "release/receipt.json\0"
    assert_raises(SharedCI::MergeVerifier::Error) { verifier.call }
    @paths = "App.swift\0"
    @pull["head"]["sha"] = S
    assert_raises(SharedCI::MergeVerifier::Error) { verifier.call }
  end
  def test_malformed_config_fails_before_api
    [ {}, @config.merge(required_checks: {}), @config.merge(branches: []),
      @config.merge(required_checks: { "bad" => [] }), @config.merge(record_only_paths: ["../escape"]) ].each do |config|
      @config = config
      assert_raises(SharedCI::MergeVerifier::Error) { verifier }
    end
    assert_empty @requests
  end
  def test_job_pagination_and_malformed_page
    path = "repos/qtmleap/App/actions/runs/12/attempts/2/jobs?per_page=100"
    good = @jobs.first
    @jobs = Array.new(100) { { "name" => "Other" } }
    @overrides = { "#{path}&page=2" => { "jobs" => [good] } }
    assert_equal S, verifier.call[:sha]
    assert_includes @requests, "#{path}&page=2"
    @overrides["#{path}&page=2"] = { "jobs" => "malformed" }
    assert_raises(SharedCI::MergeVerifier::Error) { verifier.call }
  end
  def test_pagination_has_finite_limit
    path = "repos/qtmleap/App/commits/#{S}/pulls?per_page=100"
    @overrides = (1..10).to_h { |page| ["#{path}&page=#{page}", Array.new(100) { { "number" => 7 } }] }
    assert_raises(SharedCI::MergeVerifier::Error) { verifier.call }
    assert_equal 10, @requests.length
  end
  def test_malformed_identity_and_event
    @run["run_attempt"] = "2"
    assert_raises(SharedCI::MergeVerifier::Error) { verifier.call }
    @event["forced"] = true
    assert_raises(SharedCI::MergeVerifier::Error) { verifier.call }
  end
end
