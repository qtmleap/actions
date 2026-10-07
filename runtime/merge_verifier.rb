# frozen_string_literal: true
require "json"
require "net/http"
require "open3"
require_relative "environment"

module SharedCI

class MergeVerifier
  class Error < StandardError; end

  SHA_PATTERN = /\A[0-9a-f]{40}\z/
  PER_PAGE = 100
  # API が同じ大きさのページを返し続けても、無限に取得しないための上限。
  MAX_PAGES = 10

  # 信頼する PR 検証ワークフローと、その job 名 (integration.yaml と一致させる)。
  # 同名の別チェックを許さないよう、名前ではなく実行のパス・イベント・head から特定する。


  class Api
    def initialize(token:)
      @token = token.to_s
      raise Error, "GITHUB_TOKEN が設定されていません。" if @token.empty?
    end

    def get(path)
      uri = URI("https://api.github.com/#{path}")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Accept"] = "application/vnd.github+json"
      request["X-GitHub-Api-Version"] = "2022-11-28"
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 30) { |http| http.request(request) }
      raise Error, "GitHub API #{path.split('?').first} が #{response.code} を返しました。" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end
  end

  class Git
    def initialize(directory)
      @directory = directory
    end

    def call(*args)
      out, status = Open3.capture2(SharedCI::Environment.child, "git", "-C", @directory, *args, err: File::NULL, unsetenv_others: true)
      raise Error, "git #{args.first} に失敗しました。" unless status.success?

      out
    end
  end

  def self.write_output(path, pr_number:, sha:)
    raise Error, "Invalid verifier output" unless sha.is_a?(String) && sha.match?(SHA_PATTERN) && pr_number.is_a?(Integer) && pr_number.positive?
    File.open(path, "a") { |file| file.write("pr_number=#{pr_number}\nsha=#{sha}\n") }
  end

  def initialize(config:, env:, event:, api:, git:, sleeper: ->(seconds) { sleep(seconds) }, attempts: 6, delay: 10)
    @config = validate_config(config)
    raise Error, "Invalid retry configuration" unless attempts.is_a?(Integer) && attempts.between?(1, 20) && delay.is_a?(Numeric) && delay >= 0
    @env = env
    @event = event
    @api = api
    @git = git
    @sleeper = sleeper
    @attempts = attempts
    @delay = delay
  end

  def call
    sha = @env.fetch("GITHUB_SHA", "")
    repo = @env.fetch("GITHUB_REPOSITORY", "")
    branch = @env.fetch("GITHUB_REF", "").delete_prefix("refs/heads/")
    verify_push(sha, repo, branch)
    parents = lineage(sha)
    pull = find_pull(repo, sha, branch)
    verify_parents(sha, parents, pull)
    verify_checks(repo, pull)
    # 検証に時間がかかる間に次のマージが入っていないことを、最後にもう一度確かめる。
    tip = @api.get("repos/#{repo}/branches/#{branch}").dig("commit", "sha")
    raise Error, "#{branch} の先端が進んでいます。新しいマージが優先されます。" unless tip == sha

    { pr_number: pull.fetch("number"), sha: sha }
  rescue TypeError, NoMethodError, KeyError, JSON::ParserError
    raise Error, "Malformed GitHub API or event response"
  end

  private

  def validate_config(config)
    raise Error, "Invalid merge configuration" unless config.is_a?(Hash)
    c = config.transform_keys(&:to_sym)
    expected = %i[repository branches workflow required_checks record_only_paths]
    raise Error, "Merge configuration must be explicit" unless c.keys.sort == expected.sort
    path = ->(value) { value.is_a?(String) && value.match?(/\A[\w.\/-]+\z/) && !value.start_with?("/") && !value.split("/").any? { |part| part == ".." || part == "." } }
    workflow = ->(value) { path.call(value) && value.match?(%r{\A\.github/workflows/[^/]+\.ya?ml\z}) }
    valid = c[:repository].is_a?(String) && c[:repository].match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}) &&
      c[:branches].is_a?(Array) && !c[:branches].empty? && c[:branches].all? { |b| b.is_a?(String) && b.match?(/\A[A-Za-z0-9_-]+\z/) } &&
      workflow.call(c[:workflow]) && c[:required_checks].is_a?(Hash) && !c[:required_checks].empty? &&
      c[:required_checks].all? { |p, names| workflow.call(p) && names.is_a?(Array) && !names.empty? && names.uniq == names && names.all? { |n| n.is_a?(String) && !n.strip.empty? && !n.match?(/[\r\n]/) } } &&
      c[:record_only_paths].is_a?(Array) && c[:record_only_paths].all? { |p| path.call(p) }
    raise Error, "Invalid merge configuration" unless valid
    # Own a snapshot so a caller cannot mutate authorization policy while waiting.
    Marshal.load(Marshal.dump(c))
  rescue NoMethodError, TypeError
    raise Error, "Invalid merge configuration"
  end

  def verify_push(sha, repo, branch)
    unless @env["GITHUB_ACTIONS"] == "true" && @env["RUNNER_ENVIRONMENT"] == "self-hosted"
      raise Error, "self-hosted runner の GitHub CI だけで実行できます。"
    end
    raise Error, "push イベントではありません。" unless @env["GITHUB_EVENT_NAME"] == "push"
    ref = @env["GITHUB_REF"]
    raise Error, "配信できないブランチです: #{branch}" unless ref == "refs/heads/#{branch}" && @config[:branches].include?(branch)
    raise Error, "CI の再実行では配信しません。" unless @env["GITHUB_RUN_ATTEMPT"] == "1"
    raise Error, "リポジトリが一致しません。" unless repo == @config[:repository]
    raise Error, "ワークフローが一致しません。" unless @env["GITHUB_WORKFLOW_REF"] == "#{repo}/#{@config[:workflow]}@#{ref}"
    raise Error, "イベントの ref が GITHUB_REF と異なります。" unless @event.is_a?(Hash) && @event["ref"] == ref
    raise Error, "イベントのリポジトリが一致しません。" unless @event.dig("repository", "full_name") == repo
    raise Error, "ブランチの新規作成はマージではありません。" unless @event["created"] == false
    raise Error, "ブランチの削除はマージではありません。" unless @event["deleted"] == false
    raise Error, "強制 push は配信しません。" unless @event["forced"] == false
    raise Error, "GITHUB_SHA が不正です。" unless sha.match?(SHA_PATTERN)
    raise Error, "push の after が GITHUB_SHA と異なります。" unless @event["after"] == sha

    before = @event["before"]
    raise Error, "push の before が不正です。" unless before.is_a?(String) && before.match?(SHA_PATTERN)
    raise Error, "push の before が全てゼロです。" if before.match?(/\A0+\z/)
  rescue TypeError, NoMethodError
    raise Error, "push イベントが不正です。"
  end

  # 複数コミットをまとめた push を、単一のマージとして配信しないために親を照合する。
  # 単一コミットの直接 push は親が一致しうるので、別途マージ済み PR との照合 (verify_parents) も必要。
  def lineage(sha)
    fields = @git.call("rev-list", "--parents", "-n", "1", sha).split
    raise Error, "マージコミットの親を取得できません。" unless fields.first == sha && fields.drop(1).all? { |p| p.match?(SHA_PATTERN) }

    parents = fields.drop(1)
    raise Error, "親の無いコミットは配信しません。" if parents.empty? || parents.length > 2
    raise Error, "first parent が push の before と一致しません。" unless parents.first == @event["before"]

    paths = @git.call("diff", "--name-only", "-z", "#{sha}^1", sha, "--").split("\0")
    raise Error, "変更の無いマージは配信しません。" if paths.empty?

    raise Error, "Record-only merge is not released" if paths.all? { |path| @config[:record_only_paths].include?(path) }

    parents
  end

  # merge commit なら 2 つ目の親が PR の head。squash は親が 1 つだけで、その head は
  # マージ SHA とは別のコミットでなければならない。head == マージ SHA は、PR を経ず
  # ブランチを fast-forward で直接 push した形なので配信しない。
  def verify_parents(sha, parents, pull)
    head = pull.dig("head", "sha")
    raise Error, "PR の head がマージ SHA と同一です (fast-forward の直接 push)。" if head == sha
    return if parents.length == 1
    raise Error, "2 つ目の親が PR の head と一致しません。" unless parents[1] == head
  end

  # commits/:sha/pulls は反映が遅れることがあるので、有限回だけ待つ。
  def find_pull(repo, sha, branch)
    matches = []
    @attempts.times do |index|
      listed = paginate("repos/#{repo}/commits/#{sha}/pulls?per_page=#{PER_PAGE}", nil)
      numbers = listed.map { |entry| entry.fetch("number") }
      raise Error, "Malformed PR numbers" unless numbers.all? { |number| number.is_a?(Integer) && number.positive? && number <= 9_999_999_999 }
      matches = numbers.uniq.filter_map do |number|
        pull = @api.get("repos/#{repo}/pulls/#{number}")
        pull if acceptable_pull?(pull, repo, sha, branch) && pull["number"] == number
      end
      break unless matches.empty?

      @sleeper.call(@delay) if index < @attempts - 1
    end
    raise Error, "#{sha} を生成したマージ済み PR が見つかりません。" if matches.empty?
    raise Error, "#{sha} を生成した PR が複数あり、特定できません。" unless matches.length == 1

    matches.first
  end

  def acceptable_pull?(pull, repo, sha, branch)
    pull["merged"] == true && pull["merge_commit_sha"] == sha && pull.dig("base", "ref") == branch &&
      pull.dig("base", "repo", "full_name") == repo && pull.dig("head", "repo", "full_name") == repo &&
      pull.dig("head", "sha").to_s.match?(SHA_PATTERN) && !pull.dig("head", "ref").to_s.empty?
  end

  # マージ後は PR の紐づく配列が空になるので使わず、実行のパス・イベント・head・元ブランチで信頼を決める。
  def verify_checks(repo, pull)
    head = pull.dig("head", "sha")
    runs = paginate("repos/#{repo}/actions/runs?head_sha=#{head}&per_page=#{PER_PAGE}", "workflow_runs")
    checks = paginate("repos/#{repo}/commits/#{head}/check-runs?per_page=#{PER_PAGE}&filter=latest", "check_runs")
    problems = []
    @config[:required_checks].each do |path, names|
      trusted = runs.select do |run|
        run["path"] == path && run["event"] == "pull_request" && run["head_sha"] == head &&
          run["head_branch"] == pull.dig("head", "ref") && run.dig("head_repository", "full_name") == repo
      end
      trusted.each do |run|
        raise Error, "Malformed trusted workflow identity" unless %w[id run_number run_attempt check_suite_id].all? { |key| run[key].is_a?(Integer) && run[key].positive? }
      end
      latest = trusted.max_by { |run| [run["run_number"].to_i, run["run_attempt"].to_i, run["id"].to_i] }
      unless latest && latest["status"] == "completed" && latest["conclusion"] == "success"
        problems << path
        next
      end
      unless %w[id run_number run_attempt check_suite_id].all? { |key| latest[key].is_a?(Integer) && latest[key].positive? }
        raise Error, "Malformed trusted workflow identity"
      end
      jobs = paginate("repos/#{repo}/actions/runs/#{latest.fetch('id')}/attempts/#{latest.fetch('run_attempt')}/jobs?per_page=#{PER_PAGE}", "jobs")
      names.each do |name|
        candidates = checks.select do |check|
          check["name"] == name && check.dig("app", "slug") == "github-actions" && check["head_sha"] == head &&
            check.dig("check_suite", "id") == latest["check_suite_id"]
        end
        raise Error, "Malformed check identity" unless candidates.all? { |entry| entry["id"].is_a?(Integer) && entry["id"].positive? }
        check = candidates.max_by { |entry| entry["id"] }
        raise Error, "Malformed check identity" if check && !(check["id"].is_a?(Integer) && check["id"].positive?)
        job = check && jobs.find { |entry| entry["name"] == name && entry["check_run_url"] == "https://api.github.com/repos/#{repo}/check-runs/#{check['id']}" }
        problems << name unless check && check["status"] == "completed" && check["conclusion"] == "success" &&
                               job && job["status"] == "completed" && job["conclusion"] == "success"
      end
    end
    raise Error, "PR の head で必須チェックが成功していません: #{problems.join(', ')}" unless problems.empty?
  end

  def paginate(path, key)
    items = []
    (1..MAX_PAGES).each do |page|
      response = @api.get("#{path}&page=#{page}")
      batch = key ? response.fetch(key) : response
      raise Error, "Malformed paginated API response" unless batch.is_a?(Array) && batch.all? { |entry| entry.is_a?(Hash) }
      items.concat(batch)
      return items if batch.length < PER_PAGE
    end
    raise Error, "#{key} が #{MAX_PAGES * PER_PAGE} 件を超えており、確認できません。"
  end
end

end
