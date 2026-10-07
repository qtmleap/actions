# Builds from an exact-SHA `git archive` copy under RUNNER_TEMP so the authorized checkout is
# never modified, and nothing generated lands inside it.
require "fileutils"
require "open3"
require_relative "../environment"

module BuildCopy
  class Error < StandardError; end

  module_function

  def inside?(path, root)
    path = File.expand_path(path)
    root = File.expand_path(root)
    path == root || path.start_with?(root + File::SEPARATOR)
  end

  def run!(*command, **options)
    _, error, status = Open3.capture3(SharedCI::Environment.child, *command, **options, unsetenv_others: true)
    raise Error, "#{command.first} failed: #{error.lines.last.to_s.strip}" unless status.success?
  rescue SystemCallError => e
    raise Error, "#{command.first} could not run: #{e.class}"
  end

  # Extracts the tree of `sha` (no .git directory, no ignored or untracked files) into `dest`.
  def extract!(repo_root:, sha:, dest:)
    raise Error, "The build copy must live outside the authorized checkout." if inside?(dest, repo_root)

    FileUtils.mkdir_p(dest, mode: 0o700)
    Open3.pipeline_r([SharedCI::Environment.child, "git", "-C", repo_root, "archive", "--format=tar", sha], unsetenv_others: true) do |tar_out, threads|
      reader, status = Open3.capture2(SharedCI::Environment.child, "tar", "-xf", "-", "-C", dest, stdin_data: tar_out.read, unsetenv_others: true)
      _ = reader
      raise Error, "tar extraction failed." unless status.success?
      raise Error, "git archive failed." unless threads.all? { |thread| thread.value.success? }
    end
    dest
  rescue SystemCallError => e
    raise Error, "Cannot create the build copy: #{e.class}"
  end

  # A pinned sibling checkout (e.g. a local Swift package) must be at exactly the pinned revision.
  def extract_sibling!(source:, rev:, dest:)
    head, status = Open3.capture2(SharedCI::Environment.child, "git", "-C", source, "rev-parse", "--verify", "HEAD^{commit}", unsetenv_others: true)
    raise Error, "Cannot read the sibling checkout revision." unless status.success?
    raise Error, "The sibling checkout is not at the pinned revision." unless head.strip == rev

    dirty, status = Open3.capture2(SharedCI::Environment.child, "git", "-C", source, "status", "--porcelain", "--untracked-files=all", unsetenv_others: true)
    raise Error, "Cannot read the sibling checkout state." unless status.success?
    raise Error, "The sibling checkout is dirty." unless dirty.empty?

    extract!(repo_root: source, sha: rev, dest: dest)
  end
end
