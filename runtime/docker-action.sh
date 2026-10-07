#!/usr/bin/env bash
set -euo pipefail
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
  --env GEM_PATH=/output/gems:/usr/local/lib/ruby/gems/3.4.0
  --env PATH=/output/gems/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  --env SHARED_ACTION_ROOT --env SHARED_HOST_ROOT --env SHARED_COMMAND --env SHARED_ADAPTER
  --env SHARED_REPO_ROOT --env SHARED_WORKING_DIRECTORY --env SHARED_GITHUB_TOKEN
  --env GITHUB_ACTIONS --env RUNNER_ENVIRONMENT --env GITHUB_SHA --env GITHUB_REF
  --env GITHUB_REPOSITORY --env GITHUB_EVENT_NAME --env GITHUB_RUN_ATTEMPT --env GITHUB_WORKFLOW_REF
  --env GITHUB_RUN_NUMBER --env QTMLEAP_ACTIONS_REVISION)
if [[ "${1:?}" == verify-merge ]]; then
  args+=(--mount "type=bind,source=$GITHUB_EVENT_PATH,target=/event.json,readonly" --env GITHUB_EVENT_PATH=/event.json)
fi
docker "${args[@]}" ruby:3.4.10@sha256:ce3b7a999d9e430e59e1a12456c631fbea3dd18948c89cf8a913c3566c77b2ae \
  ruby /shared/runtime/actions.rb "$1"
while IFS= read -r line; do printf '%s\n' "$line" >> "$GITHUB_OUTPUT"; done < "$out/output"
while IFS= read -r line; do printf '%s\n' "$line" >> "$GITHUB_ENV"; done < "$out/env"
