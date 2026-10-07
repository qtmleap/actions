# actions

プロジェクト横断で使い回す GitHub Actions の再利用ワークフロー置き場。

**このリポジトリが public なのは、別 org の private リポから呼べるようにするため**です。private リポの
再利用ワークフローは同一 org (または同一 Enterprise) 内からしか呼べず、`mito-shogi` / `qtmleap` /
`rshogi` / `IPA-Patch` / `shielune` のように org をまたぐ構成では public ホストが唯一の選択肢に
なります ([Sharing actions and workflows from your private repository](https://docs.github.com/en/actions/how-tos/reuse-automations/share-across-private-repositories))。

ワークフロー定義そのものが公開されるだけで、シークレットは呼び出し側から渡すため漏れません。

## backmerge — リリース後に develop を master へ追従させる

`feature → develop → master` のフローでは、リリースを**マージコミット**で行うため
(squash すると次回の「develop is ahead of master」判定が壊れる)、マージ直後は `master` だけが
1 コミット先行し、`develop` は放置すると毎リリース 1 回ずつ取り残されます。

このワークフローは `master` を `develop` へ **fast-forward push** します。リリース直後の
`master` は `merge(master_prev, develop_head)` なので `develop` は必ず `master` の祖先であり、
push は常に fast-forward になります。結果 `develop == master` となり、back-merge PR 方式と違って
**マージコミットが 1 つも増えません**。

git 操作しか行わないので**言語非依存**です。TypeScript / Rust / Python / Theos いずれでも同じものが
使えます。

### 使い方

呼び出し側に `.github/workflows/backmerge.yaml` を置きます。

```yaml
name: Back-merge

on:
  pull_request:
    branches: [master]
    types: [closed]

permissions:
  contents: write

jobs:
  backmerge:
    if: github.event.pull_request.merged == true
    uses: qtmleap/actions/.github/workflows/backmerge.yaml@v1
```

`permissions: contents: write` は**呼び出し側に必要**です。再利用ワークフローは呼び出し元より
広い権限を持てません。

### 入力

| 名前 | 既定値 | 説明 |
|---|---|---|
| `source` | `master` | 追従元 (リリース先) のブランチ |
| `target` | `develop` | 追従先 (開発) のブランチ |
| `runner` | `["ubuntu-latest"]` | ランナーのラベル。**JSON 配列**で渡す |

セルフホストランナーを使う場合:

```yaml
    uses: qtmleap/actions/.github/workflows/backmerge.yaml@v1
    with:
      runner: '["self-hosted","ubuntu-24.04"]'
```

`main` を使うリポジトリ:

```yaml
    with:
      source: main
```

### 安全策

- push 前に `git merge-base --is-ancestor` を確認し、fast-forward できない場合 (リリース後に
  `develop` へ別のコミットが入っていた場合) は **push せず `::warning::` を出して正常終了**します。
  従来どおり back-merge PR を手動で作る運用に落ちます
- **`--force` は使いません**。fast-forward でなければ push が失敗して止まるのが正しい挙動です
- 既に同一 SHA なら何もしません (冪等)
- 呼び出し側が `if: github.event.pull_request.merged == true` を書き忘れても、ワークフロー内で
  同じ条件を再確認して止まります

### 副作用

- `GITHUB_TOKEN` による push は他のワークフローを起動しないため、`on: push` のワークフローは
  再発火しません
- デプロイが `pull_request: types: [closed]` 発火なら、この push ではデプロイは走りません。
  リリース後は `develop` と `master` の内容が同一なので再デプロイは不要です

## バージョニング

`@v1` のようなメジャータグを参照してください。破壊的変更を入れるときは `v2` を切り、`v1` は
そのまま残します。

## Shared Apple CI/CD (Task 1 hub)

Apple consumers use **full commit SHAs**, not the backmerge tag convention above.
The stable inputs, Ruby APIs, lock schema and adapter boundaries are in
[docs/consumer-contract.md](docs/consumer-contract.md). The scope and implementation
plan are in [docs/shared-apple-cd.md](docs/shared-apple-cd.md) and
[the Task 1 plan](docs/superpowers/plans/2026-10-07-shared-apple-cd.md).

- `runtime/legacy/`: eleven common modules, configured by the consumer's local
  release_config via `SharedCI.load_legacy(name, app_root:)`. No runtime app default.
- `runtime/merge_verifier.rb`: explicit policy, paginated trusted PR checks bound
  to jobs from the latest exact run attempt. Consumers retain every required check.
- `runtime/mac_dmg.rb`: shared Developer ID, notarization, staple/assessment, UDZO
  signing and final-byte checksum lifecycle. No upload, promotion or publication.
- `actions/`: seven step-level composites. CI Ruby/merge steps run in the observed
  pinned Ruby 3.4.10 Docker image with readonly source/runtime. Native steps require
  installed Ruby; setup-ruby uses installed rbenv MRI and job-owned frozen Bundler.
- `templates/`: reviewed local consumer trust anchor and compatibility wrappers.
  A cold bootstrap uses only exact public Git objects outside app source. Supplied
  runtime roots are still digest/list/YAML verified; tampered caches are not repaired.

### Consumer integration boundary

Codex must publish a reviewed full SHA, generate the lock from **that checkout**
with `bun tools/runtime-lock.mjs <FULL_SHA>`, and change every shared uses reference
and lock revision together. Copy the loader template into the consumer and retain
it as local reviewed source. Thin module loaders call load_legacy; specialized lanes
remain app-owned. Merge compatibility config must preserve the consumer's exact
REQUIRED map, error superclass, branch/workflow and record-only paths. Connect/Qualia
can use the factory with their existing constants without adopting legacy config.

The protected App private key is input-only to repository-token. That action permits
only match/QuantumLeap contents:read and retains official post revocation. ASC,
MATCH, TESTFLIGHT, MUSICFIN and package credentials remain caller step-scoped. Native
adapters may receive credentials in their parent, but must scrub all compile/recovery
children using SharedCI::Environment.child (legacy modules do this themselves).
Never pass credentials in argv-json. Complete private package resolution and remove
package authority before compilation. Revalidate clean exact live source immediately
before upload; a secret-free merge result is not itself upload authorization.

Caller cleanup is an independent `if: always()` run-adapter invocation with operation
`cleanup`, no secret env. Shared action scrubs even accidentally inherited credentials
for that operation. Receipt preservation is **another** independent `if: always()`
release-record step, never conditional on cleanup success. Choose explicit `*.json`
receipt paths, not work/keychain/recovery directories. `expected-source-sha` defaults
to `github.sha`; every present sha/source_sha/merge_sha must match, preventing an old
tracked Musicfin receipt from being uploaded for a failed new merge. Fresh receipts
remain independent of cleanup failure. All composites accept `repo-root: Kotatsu`
for nested checkouts (default `.`); working-directory/adapter paths are app-relative.
Validation accepts at most 20
regular non-symlink JSON objects, each <=1 MiB, scalar receipt fields only, then uploads
a private snapshot. Failed recovery state remains owned by the consumer cleanup.
Do not combine deployment, cleanup and records in a single adapter operation.

Keep macOS 26/27, TestFlight tvOS→iOS sequencing, unsigned templates, Connect draft
physical evidence finalization, Qualia immutable R2/Sparkle promote and Cloudflare
policy as separate consumer contracts. DMG app-specific entitlement/icon/Sparkle
checks surround the shared lifecycle. This hub never selects a universal platform
lane or replaces a caller job.

### Verification / publication gate

Run on an integration host with Docker and Bun 1.3.6 (no host Ruby required):

```sh
ruby_image=ruby:3.4.10@sha256:ce3b7a999d9e430e59e1a12456c631fbea3dd18948c89cf8a913c3566c77b2ae
docker run --rm --network none --user "$(id -u):$(id -g)" --mount "type=bind,source=$PWD,target=/work,readonly" --tmpfs /tmp:rw,nosuid,nodev --workdir /work --env HOME=/tmp "$ruby_image" bash -euc 'ruby test/run_all.rb; ruby tools/action_contract.rb'
docker run --rm --network none --mount "type=bind,source=$PWD,target=/work,readonly" --workdir /work rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 -color
bash -n runtime/*.sh runtime/legacy/*.sh
bash test/shell_regressions.sh
bun tools/static-check.mjs
```

Hub CI runs on `[self-hosted, Linux, X64, ubuntu-latest, docker]`, rejects fork PRs
at the job guard before checkout, and uses version-pinned Docker actionlint. Common
legacy suites can also be run one process per consumer with
`SHARED_CI_TEST_APP_ROOT=/readonly/app ruby test/legacy/release_pipeline_test.rb`
(and the other legacy suites). Fixtures/build copies are temporary; app roots are
read-only inputs. Bootstrap/DMG tests use fake Git/native commands, never signing,
notary submissions or publication. The zero SHA is accepted **only** by the explicit
Bootstrap.verify! test flag; native loader/actions reject it. Generate a zero-SHA
manifest for local digest checks, not consumer activation.

Codex natively verified official pins: create-github-app-token v3.2.0
`bcd2ba49218906704ab6c1aa796996da409d3eb1` (unchanged), checkout v5.0.0
`08c6903cd8c0fde910a37f88322edcfb5dd907a8`, upload-artifact v4.6.2
`ea165f8d65b6e75b540449e92b4886f43607fa02`, and setup-bun v2.0.2
`735343b667d3e6f658f44d0eca948eb6282f2b76`. The also-verified artifact v7.0.1
is not selected: v4 retains the proven runner runtime. Native tests/runner
compatibility and independent review still gate publication.

Ruby/Python/Docker/actionlint were unavailable on the implementation host. Native
behavioral suites and independent review remain publication gates. Bun is also
unavailable on the fix host; CI/static contract checks remain pending. Bash syntax
and offline fake-command checks are not substitutes for native Ruby/Docker suites.
