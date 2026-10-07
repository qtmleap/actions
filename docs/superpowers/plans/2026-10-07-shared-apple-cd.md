# Shared Apple CI/CD Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development with independent ownership and review. Workers leave changes uncommitted; Codex owns integration and Git history.

**Goal:** Make qtmleap Apple app CI and CD execute shared source while preserving platform-specific publication contracts.

**Architecture:** Small composite actions run inside ordinary caller jobs. A pinned runtime supplies the legacy TestFlight engine and universal merge verifier; app config, lanes and distribution adapters stay local.

**Tech Stack:** GitHub Actions composites, Ruby 3.4.10, Bash, Python 3, Bun 1.3.6, pinned Docker images.

**Spec:** docs/shared-apple-cd.md

## Global Constraints

- Keep existing caller workflow paths/job names, triggers, environments, concurrency, default branches and distinct Mac26/Mac27 labels.
- Pin consumer action references to one full shared commit SHA; .github/shared-actions.lock.json records the same revision and runtime file digests. No branch/tag or local engine fallback.
- Protected TestFlight secrets retain their existing MUSICFIN_/TESTFLIGHT_ namespaces. Do not read, log or persist secret values in source. Nested token action uses the verified v3.2.0 SHA and explicit match/QuantumLeap contents:read scope.
- Shared source runs outside app checkout. Native bootstrap uses verified Git objects/cache plus file digests; CI uses github.action_path and rejects pin/content mismatch.
- All required checks stay real checks on the PR head. Core verifier binds check_run_url to jobs from the trusted run's exact attempt, paginates and validates identities.
- Keep existing recovery journals and upload receipts. Always-run independent cleanup is credential-free; failed restoration retains its state. Evidence preservation is independent of cleanup result.
- No merges, signed local deployments, new profiles/certificates or external publication during this refactor. Commit through installed guarded Git only after independent review/tests.
- Codex verified official Git tags natively: actions/checkout v5.0.0 = 08c6903cd8c0fde910a37f88322edcfb5dd907a8; actions/upload-artifact v4.6.2 = ea165f8d65b6e75b540449e92b4886f43607fa02; oven-sh/setup-bun v2.0.2 = 735343b667d3e6f658f44d0eca948eb6282f2b76; actions/create-github-app-token v3.2.0 = bcd2ba49218906704ab6c1aa796996da409d3eb1. Use these observed full pins for new hub dependencies.

## Review Focus

- Forged checks, malformed pagination, stale successful attempts and direct pushes must not authorize upload.
- Cache tampering or disagreement between YAML and lock must fail before credential use.
- Cleanup failure or iOS failure after tvOS success must preserve prior confirmed receipts.
- Credentials must not reach compilation or recovery children, including Qualia Mac package authorization.
- DMG historical build/promote, physical evidence and website destination rules must retain their separate semantics.

## Task 1: Shared hub

Ownership: this repository only; do not modify consumers.

- [ ] Add behavioral tests first for configured SharedCI::MergeVerifier, invalid config, latest-attempt job/check linkage and record-only exclusion; prove meaningful failures.
- [ ] Implement runtime/merge_verifier.rb with explicit config: repository, branches, workflow, required_checks, record_only_paths. Preserve injectable env/event/api/git/sleeper/attempts/delay and outputs {sha:, pr_number:}. Own credential scrubbing without consumer DeploymentPolicy imports. Provide compatibility wrapper documentation/template retaining existing public APIs and translating errors.
- [ ] Extract eleven common legacy modules into runtime/legacy (release_config stays local), with runtime configuration explicitly loaded before modules. Expose SharedCI.load_legacy(name, app_root:) and direct merge/policy CLI entrypoints without __dir__ assumptions.
- [ ] Extract runtime/mac_dmg.rb for both DMG adapters: verify Developer ID/team, notarize app ZIP and require Accepted, staple/validate/assess app, stage named app plus Applications symlink, create UDZO, sign/verify DMG, notarize/staple/validate/assess/verify DMG, then calculate final SHA256. Explicit inputs app/dmg/team/identity/volume/app-name/checksum-path plus ASC key path or decoded private temporary key content. Child environment is credential-free; API key content never enters argv/output. App-specific entitlement/icon/Sparkle validation remains before/after this lifecycle in adapters. Tests inject native command runner and confirm failure stops publication, checksum follows last mutation and temporary keys are deleted.
- [ ] Add actions/ruby-check, actions/verify-merge, actions/apple-toolchain, actions/setup-ruby, actions/repository-token, actions/run-adapter, actions/release-record. They use their own action_path, explicit inputs and caller contexts. No reusable job-level deployment workflow or universal platform switch framework.
- [ ] ruby-check accepts trusted command and working-directory, mounts source readonly and runtime readonly into pinned Ruby Docker; verify-merge accepts adapter path + github-token and outputs sha/pr_number using writable output only. Export verified runtime root for consumers. Setup-ruby reads locked Bundler, uses existing rbenv MRI, job-owned RUNNER_TEMP gems/config, frozen install; no ruby/setup-ruby host toolcache assumptions.
- [ ] repository-token accepts client-id/private-key/repository (match or QuantumLeap only), uses pinned official action read scope and normal post revocation. run-adapter executes a versioned app adapter with validated operation/JSON argv, exports runtime; cleanup remains an independent caller always step without secret env. release-record preserves only bounded JSON receipts, caller-selected artifact name/path/missing behavior.
- [ ] Implement runtime bootstrap/verification API and a small consumer loader template: full SHA + exact runtime digest list, same revision across uses references, cold bootstrap outside source and tampering rejection. Local tests may use supplied root only when content verifies; no unchecked override.
- [ ] Move common behavioral fixtures/suites into hub and expose cross-consumer contract tests. Add self-hosted Linux Docker CI and actionlint. Document pinned usage and adapter boundary.
- [ ] Run shared suite, bootstrap/tamper tests, mocked setup and cleanup/record ordering, actionlint; independent review before commit/publish.

## Task 2: Four legacy consumers

Ownership: QRReader, InstantNX, ChatClock, Interceptor isolated rollout paths only.

- [ ] Adopt shared loader/lock and replace copied eleven modules with thin compatibility loaders; keep release_config, app resources/generators/project contracts and release semantics.
- [ ] Use common Ruby CI, merge verification, Ruby setup, scoped tokens, adapter execution/cleanup and receipt preservation. Keep per-app verified env names and all trusted check identities.
- [ ] Shared merge wrapper adopts strongest core while existing tests remain valid behavioral coverage; adjust fixtures for exact run-attempt linkage, never relax required checks.
- [ ] Move byte-identical common release shell implementations/tests to hub or thin wrappers, retain app-specific contracts. Interceptor sibling and simulator private dependency resolution stay intact.
- [ ] Run each complete suite, project contract and workflow lint against actual shared root; native bootstrap must work cold and reject modified cache. Receipt artifacts use always condition and ignore when absent, so confirmed upload survives cleanup failure.
- [ ] Do not commit/push until final full hub SHA is supplied by Codex after review/publication; update all references and lock consistently.

## Task 3: Remaining consumers and distribution adapters

Ownership: Musicfin, Kotatsu, Immerse, Connect, Qualia isolated rollout paths only.

- [ ] Adopt shared merge core via compatibility wrappers in the eight distributable apps, retaining own required checks/config/error classes. Keep Musicfin/Kotatsu custom lanes and Connect/Qualia durable recovery implementation.
- [ ] Adopt common CI/toolchain/Ruby/token/adapter/record actions in TestFlight and unsigned-template workflows. Keep caller environment and tvOS→iOS sequencing; receipts persist independently of later failure.
- [ ] Adopt common runtime/setup/adapter code in Connect and Qualia DMG CD. Convert Connect hosted Linux publish job to self-hosted Docker-safe execution. Preserve draft/physical-evidence finalization and Qualia immutable R2/Sparkle promote behavior.
- [ ] Qualia Mac explicitly resolves QuantumLeap with a distinct scoped App token, removes dependency authority before native build and freezes packages. Do not use match authority for package access or expose signing/ASC/Sparkle credentials to build children.
- [ ] Adopt applicable common checks/adapter execution in Qualia Cloudflare CD without replacing trusted policy/source SHA, staging/production or Bun frozen build behavior.
- [ ] Run full affected release/helper suites and workflow contract/actionlint checks. Run Musicfin exact mandated unsigned simulator build and strict formatting. Verify no app source changed beyond necessary package-build authentication mechanics.
- [ ] Use only final reviewed/published shared SHA, leaving commits/push/PR integration to Codex.

## Task 4: Integration and review

- [ ] Codex independently inspects actual hub and nine consumer diffs/test evidence. Fresh reviewer audits source, pin coherence, adapters and failures. Claude review is retried only after confirmed terminal failures; if unavailable, disclose and use native independent reviewer.
- [ ] Commit/publish shared hub feature branch with native gh identity checker and open PR to master. Pin all consumers to that published immutable SHA and run final tests before normal guarded commits/pushes to their existing PR branches.
- [ ] Update all existing app PR descriptions around final shared implementation and attach the hub PR. Verify live remote SHAs and CI results within rate limits; no deployment trigger occurs on feature branch pushes.
- [ ] Report actual checks, pending items and no TestFlight/DMG publication. Separate App installation confirmation/signing prerequisite PR from completed source migration.

User runner-label simplification: retain macos-26/macos-27 profiles, but caller runs-on uses only [self-hosted, macos-26] or [self-hosted, macos-27]. Remove redundant macOS/ARM64 labels; existing runtime toolchain validation remains.
