#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in ruby-check|verify-merge) [[ "$#" -eq 1 ]] || exit 2 ;; *) exit 2 ;; esac
operation=$1
root="$(cd "${SHARED_ACTION_PATH}/../.." && pwd -P)"
source_root="$(cd "$GITHUB_WORKSPACE" && pwd -P)"
temp="$(cd "$RUNNER_TEMP" && pwd -P)"
case "$root$source_root$temp" in *','*|*$'\n'*|*$'\r'*) exit 1 ;; esac
case "$temp/" in "$source_root/"*|"$root/"*) exit 1 ;; esac
out="$(mktemp -d "$temp/shared-docker.XXXXXX")"
trap 'rm -rf "$out"' EXIT
mkdir -p "$out/home" "$out/gems/bin"
# Prove the mapped UID can write its owned gem home before running any check.
probe="$out/gems/.writable"
: > "$probe"
rm "$probe"
touch "$out/output" "$out/env"
export SHARED_ACTION_ROOT=/shared SHARED_HOST_ROOT="$root"
export SHARED_REPO_ROOT="${SHARED_REPO_ROOT:-.}"
export SHARED_COMMAND="${SHARED_COMMAND:-}" SHARED_ADAPTER="${SHARED_ADAPTER:-}"
export SHARED_GITHUB_TOKEN="${SHARED_GITHUB_TOKEN:-}" SHARED_WORKING_DIRECTORY="${SHARED_WORKING_DIRECTORY:-.}"
args=(run --rm --user "$(id -u):$(id -g)" --cap-drop ALL --security-opt no-new-privileges
  --mount "type=bind,source=$source_root,target=/source,readonly"
  --mount "type=bind,source=$root,target=/shared,readonly"
  --mount "type=bind,source=$out,target=/output"
  --tmpfs /tmp:rw,exec,nosuid,nodev
  --workdir /source
  --env GITHUB_WORKSPACE=/source --env GITHUB_OUTPUT=/output/output --env GITHUB_ENV=/output/env
  --env HOME=/output/home --env RUNNER_TEMP=/output --env GEM_HOME=/output/gems
  # 固定した Ruby 3.4.10 イメージの標準 gem は読み、追加 gem の書き込み先だけを分離する。
  --env GEM_PATH=/output/gems:/usr/local/lib/ruby/gems/3.4.0
  --env PATH=/output/gems/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  --env SHARED_ACTION_ROOT --env SHARED_HOST_ROOT --env SHARED_COMMAND --env SHARED_ADAPTER
  --env SHARED_REPO_ROOT --env SHARED_WORKING_DIRECTORY --env SHARED_GITHUB_TOKEN
  --env GITHUB_ACTIONS --env RUNNER_ENVIRONMENT --env GITHUB_SHA --env GITHUB_REF
  --env GITHUB_REPOSITORY --env GITHUB_EVENT_NAME --env GITHUB_RUN_ATTEMPT --env GITHUB_WORKFLOW_REF
  --env GITHUB_RUN_NUMBER --env QTMLEAP_ACTIONS_REVISION)
if [[ "$operation" == verify-merge ]]; then
  args+=(--mount "type=bind,source=$GITHUB_EVENT_PATH,target=/event.json,readonly" --env GITHUB_EVENT_PATH=/event.json)
fi
docker "${args[@]}" ruby:3.4.10@sha256:ce3b7a999d9e430e59e1a12456c631fbea3dd18948c89cf8a913c3566c77b2ae \
  ruby /shared/runtime/actions.rb "$operation"

protocol_error() { printf '%s\n' '::error::Unsafe container metadata; host files were not changed.' >&2; exit 1; }
metadata_file() {
  local file=$1 size raw='' controls=$'[\001-\011\013-\037\177]' LC_ALL=C
  [[ -f "$file" && ! -L "$file" && -O "$file" ]] || protocol_error
  size=$(/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /usr/bin/wc -c < "$file") || protocol_error
  size=${size//[[:space:]]/}
  [[ "$size" =~ ^[0-9]+$ && "${#size}" -le 4 && "$size" -le 8192 ]] || protocol_error
  # read は NUL を捨てるため、行として解釈する前にバイナリ入力を拒否する。
  if IFS= read -r -d '' raw < "$file"; then protocol_error; fi
  [[ "$raw" != *$controls* ]] || protocol_error
}
metadata_file "$out/env"
metadata_file "$out/output"
root_seen=0 revision_seen=0 metadata_revision=''
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    QTMLEAP_ACTIONS_ROOT=*)
      [[ "$root_seen" -eq 0 && "${line#*=}" == "$root" ]] || protocol_error
      root_seen=1 ;;
    QTMLEAP_ACTIONS_REVISION=*)
      [[ "$revision_seen" -eq 0 ]] || protocol_error
      metadata_revision=${line#*=}
      [[ "$metadata_revision" =~ ^[0-9a-f]{40}$ && "$metadata_revision" != 0000000000000000000000000000000000000000 ]] || protocol_error
      [[ "${QTMLEAP_ACTIONS_REVISION+provided}" != provided || "$metadata_revision" == "$QTMLEAP_ACTIONS_REVISION" ]] || protocol_error
      revision_seen=1 ;;
    *) protocol_error ;;
  esac
done < "$out/env"
[[ "$root_seen" -eq 1 && "$revision_seen" -eq 1 ]] || protocol_error
sha_seen=0 pr_seen=0 metadata_sha='' metadata_pr=''
if [[ "$operation" == ruby-check ]]; then
  [[ ! -s "$out/output" ]] || protocol_error
else
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      sha=*)
        [[ "$sha_seen" -eq 0 ]] || protocol_error
        metadata_sha=${line#*=}
        [[ "$metadata_sha" =~ ^[0-9a-f]{40}$ && "$metadata_sha" == "${GITHUB_SHA:-}" ]] || protocol_error
        sha_seen=1 ;;
      pr_number=*)
        [[ "$pr_seen" -eq 0 ]] || protocol_error
        metadata_pr=${line#*=}
        [[ "$metadata_pr" =~ ^[1-9][0-9]{0,9}$ ]] || protocol_error
        pr_seen=1 ;;
      *) protocol_error ;;
    esac
  done < "$out/output"
  [[ "$sha_seen" -eq 1 && "$pr_seen" -eq 1 ]] || protocol_error
fi
for destination in "${GITHUB_ENV:?}" "${GITHUB_OUTPUT:?}"; do
  [[ -f "$destination" && ! -L "$destination" && -O "$destination" && -w "$destination" ]] || protocol_error
done
# 両方の入力を検証し終えてから、許可した値だけを新しい単一行として転記する。
printf 'QTMLEAP_ACTIONS_ROOT=%s\nQTMLEAP_ACTIONS_REVISION=%s\n' "$root" "$metadata_revision" >> "$GITHUB_ENV"
if [[ "$operation" == verify-merge ]]; then
  printf 'sha=%s\npr_number=%s\n' "$metadata_sha" "$metadata_pr" >> "$GITHUB_OUTPUT"
fi
