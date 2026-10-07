# Task 1 fix handoff

Hub only; consumer files and all token pins are unchanged. Leave uncommitted.

## Consumer interface changes (before adopting the final hub pin)

- All seven composites: `repo-root` defaults to `.`. Nested Kotatsu callers must
  set `repo-root: Kotatsu` on **every** composite, including token, record, setup
  and toolchain. Helpers resolve it inside the canonical workspace and reject
  traversal/symlinks before reading that app's lock. Adapter/working-directory
  paths and relative receipt globs are app-relative.
- release-record: `expected-source-sha` defaults to `github.sha`. At least one
  sha/source_sha/merge_sha is required; every present source field must match.
  Stale tracked Musicfin records are rejected, not uploaded under a new merge.
  core_sha is a dependency identifier, not the release source binding. Fresh
  receipts remain independent of a failed cleanup adapter.
- apple-toolchain: `26`/`27` major profiles or exact full versions within those
  profiles; credential-free probes require Darwin ARM64 and matching macOS,
  Xcode and iphoneos SDK majors. No global developer selection change.
- MacDMG checksum is `digest  basename\n`; creation has no overwrite flag,
  and hdiutil verifies final stapled bytes before the checksum is written.
- Environment.child returns a complete explicit environment: credentials nil,
  only provided noncredentials preserved. Spawn with `unsetenv_others: true`.
  Agent sockets and Bundler registry credentials are scrubbed; owned gem config
  remains. Noncleanup adapter parents still receive explicit step credentials.
- setup-ruby exports job-owned outside-source FL_REPORT_PATH/FASTLANE_SKIP_DOCS;
  Docker Ruby checks use writable owned GEM_HOME/GEM_PATH and gems/bin PATH.

The extracted legacy ci-release.sh/ci-release-cleanup.sh were reviewed and left
unchanged: explicit app-root argv and shared cleanup sibling are retained.
No publication, credentials or recovery policy was replaced.

## Regression coverage added/strengthened

Strict fake Git rejects the invalid detach-plus-path checkout; cold bootstrap
also exercises no RUNNER_TEMP, and tampered caches remain rejected both via an
exported root and by rediscovery. BuildCopy has a real local Git-tree/archive
pipeline regression without staging/committing; a local gem fixture installs with
`--local` (no network). Receipt schema/source tests, actual failed-cleanup then
fresh-snapshot tests, explicit/empty environment child tests, nested checkout
setup/adapter/record tests, final DMG format/verify-failure/key-cleanup tests, and
fake-command toolchain/Docker launcher rejection tests cover the findings.
Fixtures canonicalize temporary roots rather than weakening symlink guards.

## Executed here

- `bash -n runtime/*.sh runtime/legacy/*.sh test/shell_regressions.sh` — passed.
- `bash test/shell_regressions.sh` — passed; fake commands only, no Apple/Docker/Ruby execution.
- `git diff --check` — passed for tracked changes (new files remain untracked).

## Codex remaining checks

Ruby, Python, Docker, Bun and actionlint are unavailable here. **No Ruby suite or
YAML/actionlint pass is claimed.** Run:

```sh
# On native MRI 3.3 (fake Apple commands only):
ruby test/run_all.rb
ruby tools/action_contract.rb
# On Bun 1.3.6:
bun tools/static-check.mjs
# Pinned Docker MRI 3.4.10 and Docker actionlint:
# Run the complete commands in README's Verification / publication gate.
```

Also run native setup/loader/record fixtures on macOS to check /var vs /private/var
normalization. Hub CI uses the exact Linux labels, a fork-PR job guard before
checkout, pinned Ruby Docker, version-pinned Docker actionlint, and the verified
Bun action. Checkout v5 and artifact v4.6.2 use Codex's verified official SHAs;
artifact v7 is intentionally not selected. Final pin/lock regeneration and
consumer integration remain Codex-owned after tests/review/publication.
