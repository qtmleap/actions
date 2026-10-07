# Consumer contract (v1)

Task 1 owns this hub only. Consumers keep release_config, lanes, triggers, environments,
checks, runner labels, cleanup/recovery and distribution/publication policy.

## Stable action inputs

All seven composites accept `repo-root` (default `.`), resolved safely inside
`GITHUB_WORKSPACE` before reading the lock or running helpers. For nested checkouts
set `repo-root: Kotatsu`; `working-directory` and adapter paths are relative to that
app root. `release-record` accepts `expected-source-sha` (default `github.sha`);
every present `sha`, `source_sha`, or `merge_sha` must equal this full SHA, and at
least one source field is required. Stale receipts fail without being uploaded.
`apple-toolchain` accepts major profiles `26`/`27` or a full Xcode version; it
checks Darwin ARM64, matching macOS and iphoneos SDK majors without changing the
global developer selection.

All remote `qtmleap/actions/actions/*@<revision>` references use one full lowercase
40-character SHA. No branch/tag refs. `.github/shared-actions.lock.json` has
`{"revision":"<same SHA>","runtime_files":{"runtime/...":"<sha256>",...}}`.
The file list is exact, including runtime scripts; generate it with
`bun tools/runtime-lock.mjs <revision>`. YAML/lock coherence is checked before use.
No unchecked local override. Local precommit tests alone may use the zero SHA with
an explicitly supplied root, with every digest still checked.

| Action | Inputs | Outputs |
| --- | --- | --- |
| ruby-check | `command`, `working-directory` (default `.`) | none |
| verify-merge | `adapter`, `github-token`, `working-directory` (default `.`) | `sha`, `pr_number` |
| apple-toolchain | `xcode-version`, `developer-dir` | none |
| setup-ruby | `ruby-version` (default `3.4.10`), `working-directory` (default `.`) | none |
| repository-token | `client-id`, `private-key`, `repository` (`match` or `QuantumLeap`) | `token` |
| run-adapter | `adapter`, `operation`, `argv-json` (default `[]`), `working-directory` (default `.`) | none |
| release-record | `name`, `path`, `if-no-files-found` (`ignore`, `warn`, `error`; default `ignore`) | none |

Verify jobs need caller permissions `contents: read`, `pull-requests: read`,
`checks: read`, `actions: read`, a full-history exact-SHA checkout with
`persist-credentials: false`, and the existing self-hosted Linux Docker labels.
Distribution jobs keep the caller's protected environment, concurrency, labels and
precredential/preupload clean-source authorization. The shared verifier does not
replace the consumer's live-source policy gate.

Commands/adapters are trusted caller source, not PR/user input. `adapter` is a
repository-relative Ruby file; `operation` is a lowercase hyphenated identifier;
`argv-json` is an array of strings. v1 adapters accept operation followed by those
arguments. Verify adapters accept no arguments and append sha/pr_number to
GITHUB_OUTPUT using MergeVerifier.write_output. No eval/shell construction of argv.
Cleanup is a **separate caller `if: always()` run-adapter step**, with no secret env.
Dispatch `cleanup` before requiring Bundler/fastlane so a failed frozen install
cannot disable credential-free recovery. setup-ruby exports the verified installed
MRI path before installation; it never falls back to another Ruby version.
Record preservation is another independent `if: always()` step even if cleanup fails.
Only bounded parsed JSON receipts may be recorded, never IPA/key/recovery directories.
A receipt is a nonempty object with scalar values; <=20 files, <=1 MiB/file, <=4096
bytes/string. Accepted fields are `sha`, `source_sha`, `merge_sha`, `pr`, `pr_number`,
`build`, `build_number`, `upload_result`, `version`, `platform`, `uploaded_at`,
`upload_confirmed`, `app_identifier`, `bundle_id`, `file`, `filename`, `sha256`,
`checksum`, `status`, `receipt_id`, `run_id`, `run_attempt`, `artifact_id`,
`notarization_id`, `release_id`, `tag`, `url`, `size`, `created_at`, `confirmed_at`,
`core_sha`, `timestamp`. `core_sha` identifies a dependency and is not a release source
binding; every release `sha`/`source_sha`/`merge_sha` must match expected-source-sha.
Unknown/nested fields and symlinks fail; missing receipts honor the caller setting.
App adapters must map specialized receipts into this nonsecret schema.

CI executes pinned Ruby Docker with source/runtime readonly and only temporary output
writable. Native consumers call the loader template before loading runtime modules.
`QTMLEAP_ACTIONS_ROOT` names the verified runtime repository root outside source;
`QTMLEAP_ACTIONS_REVISION` is the expected full SHA. Both are revalidated, not trusted.
Native cold bootstrap retrieves the exact public Git commit, validates Git objects and
all runtime digests and materializes outside source; it uses no app/dependency token.

## Ruby APIs

After loader verification, require `<QTMLEAP_ACTIONS_ROOT>/runtime/shared_ci` for
the public API (or the individual module). Runtime roots refer to the hub repository
root, not its `runtime` subdirectory. Native actions need an installed Ruby; Linux
Ruby checks/merge verification use Docker. Checkout must set `persist-credentials:
false`. Apple consumers must also pin any shared backmerge reference to the same
revision; tag-pinned backmerge usage outside this rollout is unchanged.

`SharedCI::MergeVerifier.new(config:, env:, event:, api:, git:, sleeper:,
attempts: 6, delay: 10).call -> {sha:, pr_number:}`. Config is an explicit Hash with
`repository`, `branches`, `workflow`, `required_checks` (workflow path => job names),
`record_only_paths`. Empty/invalid config fails closed at construction. API responds
to get(path); Git responds to call(*argv). SharedCI owns credential-free Git children.
`SharedCI::MergeVerifier::Error`, `Api.new(token:)`, `Git.new(directory)` and
`.write_output(path, sha:, pr_number:)` are public. See compatibility template for
factory retaining legacy REQUIRED/Error/Api/Git/initialize/write_output/CLI and
translating shared errors to the consumer error superclass.

`SharedCI.load_legacy(name, app_root:)` loads that app's
`fastlane/lib/release_config.rb` **before** one of the eleven legacy modules.
One app config per Ruby process; switching app roots fails. Existing top-level
legacy APIs are retained. No hub release_config and no inferred app root.
Policy CLI: `ruby runtime/policy_cli.rb <app-root>`;
merge CLI: `ruby runtime/merge_cli.rb <config.json> <app-root>`.

`SharedCI::MacDMG.new(runner:).call(app:, dmg:, team:, identity:, volume:,
app_name:, checksum_path:, key_id:, issuer:, key_path: nil, key_content: nil)`
returns final SHA256. Supply exactly one ASC key source; decoded key_content is
written mode 0600 to a private temporary directory and deleted on every exit.
The injected runner receives `(credential_free_environment, argv)` and returns
stdout or raises. Shared lifecycle verifies Developer ID/team, notarizes/staples/
assesses app, stages named app and Applications symlink, creates UDZO, signs,
notarizes/staples/assesses/verifies DMG (including hdiutil verify after stapling)
and hashes final bytes. checksum_path contains `digest  basename\n`, not JSON;
DMG creation refuses overwrite. setup-ruby exports job-owned outside-source
`FL_REPORT_PATH` and `FASTLANE_SKIP_DOCS=true` alongside its owned Bundler config.
Children use `Environment.child(provided_env)` and `unsetenv_others: true`; omitted
noncredentials are not inherited, agent sockets/registry credentials are scrubbed. Adapters retain
entitlements/icons/Sparkle validation and all build/promote/physical evidence,
R2/website destination and publication decisions. The runtime never publishes.

## Pin publication gate

No final consumer pin exists until Codex reviews/publishes the hub. Verify any
new official third-party SHA before activation. Placeholder third-party pins are
not permitted: unavailable official pins block the affected action explicitly.
Tests and Docker actionlint must pass before publication; see README.

User runner-label simplification: retain macos-26/macos-27 profiles, but caller runs-on uses only [self-hosted, macos-26] or [self-hosted, macos-27]. Remove redundant macOS/ARM64 labels; existing runtime toolchain validation remains.

Central behavioral suites ship in runtime/test/legacy and are covered by the runtime digest lock. Consumers set SHARED_CI_TEST_APP_ROOT and delegate to these verified files; native cold bootstrap needs no unverified test download. Hub test/legacy files are forwarding entrypoints.
