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
