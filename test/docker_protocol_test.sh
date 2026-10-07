#!/usr/bin/env bash
# コンテナが返す値でホストの次のステップを変更できないことを確かめる。
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
temp=$(mktemp -d)
temp=$(cd -- "$temp" && pwd -P)
trap 'rm -rf "$temp"' EXIT
mkdir -p "$temp/bin" "$temp/source" "$temp/runner" "$temp/fixture"
export PATH="$temp/bin:$PATH"
export GITHUB_WORKSPACE="$temp/source" RUNNER_TEMP="$temp/runner"
export SHARED_ACTION_PATH="$root/actions/ruby-check" SHARED_REPO_ROOT=.
export SHARED_COMMAND=true GITHUB_EVENT_PATH="$temp/event.json"
export GITHUB_ENV="$temp/host-env" GITHUB_OUTPUT="$temp/host-output"
export PROTOCOL_FIXTURE="$temp/fixture"
export QTMLEAP_ACTIONS_REVISION=1111111111111111111111111111111111111111
export GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf '{}\n' > "$GITHUB_EVENT_PATH"
cat > "$temp/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'called\n' >> "$PROTOCOL_FIXTURE/called"
out=''
for arg in "$@"; do
    if [[ "$arg" == type=bind,source=*,target=/output ]]; then
        out=${arg#type=bind,source=}; out=${out%,target=/output}
    fi
done
[[ -n "$out" ]]
cp "$PROTOCOL_FIXTURE/env" "$out/env"
cp "$PROTOCOL_FIXTURE/output" "$out/output"
case "${PROTOCOL_FILE_MODE:-}" in
    symlink-env) rm "$out/env"; ln -s "$PROTOCOL_FIXTURE/env" "$out/env" ;;
    symlink-output) rm "$out/output"; ln -s "$PROTOCOL_FIXTURE/output" "$out/output" ;;
    directory-env) rm "$out/env"; mkdir "$out/env" ;;
    directory-output) rm "$out/output"; mkdir "$out/output" ;;
esac
SH
chmod +x "$temp/bin/docker"
failures=0
checks=0
reset_fixture() {
    printf 'host-env-seed\n' > "$GITHUB_ENV"
    printf 'host-output-seed\n' > "$GITHUB_OUTPUT"
    cp "$GITHUB_ENV" "$temp/before-env"
    cp "$GITHUB_OUTPUT" "$temp/before-output"
    printf 'QTMLEAP_ACTIONS_ROOT=%s\nQTMLEAP_ACTIONS_REVISION=%s\n' "$root" "$QTMLEAP_ACTIONS_REVISION" > "$PROTOCOL_FIXTURE/env"
    : > "$PROTOCOL_FIXTURE/output"
    : > "$PROTOCOL_FIXTURE/called"
    unset PROTOCOL_FILE_MODE
}
reject_fixture() {
    local label=$1 operation=${2:-ruby-check} good=1
    checks=$((checks + 1))
    if bash "$root/runtime/docker-action.sh" "$operation" > "$temp/log" 2>&1; then good=0; fi
    cmp -s "$GITHUB_ENV" "$temp/before-env" || good=0
    cmp -s "$GITHUB_OUTPUT" "$temp/before-output" || good=0
    if [[ "$good" -eq 1 ]]; then printf 'ok   %s\n' "$label"; else printf 'FAIL %s\n' "$label"; failures=$((failures + 1)); fi
}
for key in BASH_ENV PATH GITHUB_ENV GITHUB_OUTPUT GITHUB_TOKEN UNKNOWN; do
    reset_fixture
    printf '%s=/malicious\n' "$key" >> "$PROTOCOL_FIXTURE/env"
    reject_fixture "host rejects injected $key"
done
for key in QTMLEAP_ACTIONS_ROOT QTMLEAP_ACTIONS_REVISION; do
    reset_fixture
    printf '%s=duplicate\n' "$key" >> "$PROTOCOL_FIXTURE/env"
    reject_fixture "host rejects duplicate $key"
done
reset_fixture; printf 'QTMLEAP_ACTIONS_ROOT<<EOF\n/malicious\nEOF\n' > "$PROTOCOL_FIXTURE/env"; reject_fixture 'host rejects multiline environment commands'
reset_fixture; printf 'BASH_ENV=/malicious' >> "$PROTOCOL_FIXTURE/env"; reject_fixture 'host rejects an unterminated malicious final line'
reset_fixture; printf '\000' >> "$PROTOCOL_FIXTURE/env"; reject_fixture 'host rejects NUL bytes'
reset_fixture; printf '\r' >> "$PROTOCOL_FIXTURE/env"; reject_fixture 'host rejects carriage returns'
reset_fixture; printf '\t' >> "$PROTOCOL_FIXTURE/env"; reject_fixture 'host rejects tabs'
reset_fixture; printf 'QTMLEAP_ACTIONS_ROOT=/wrong\nQTMLEAP_ACTIONS_REVISION=%s\n' "$QTMLEAP_ACTIONS_REVISION" > "$PROTOCOL_FIXTURE/env"; reject_fixture 'host rejects a mismatched runtime root'
for revision in 2222222222222222222222222222222222222222 0000000000000000000000000000000000000000 invalid; do
    reset_fixture
    printf 'QTMLEAP_ACTIONS_ROOT=%s\nQTMLEAP_ACTIONS_REVISION=%s\n' "$root" "$revision" > "$PROTOCOL_FIXTURE/env"
    reject_fixture "host rejects revision $revision"
done
reset_fixture; : > "$PROTOCOL_FIXTURE/env"; reject_fixture 'host rejects missing runtime metadata'
reset_fixture; for ((i=0;i<8200;i++)); do printf A >> "$PROTOCOL_FIXTURE/env"; done; reject_fixture 'host rejects oversized metadata'
for mode in symlink-env symlink-output directory-env directory-output; do
    reset_fixture; export PROTOCOL_FILE_MODE=$mode; reject_fixture "host rejects $mode"
done
reset_fixture; printf 'sha=%s\n' "$GITHUB_SHA" > "$PROTOCOL_FIXTURE/output"; reject_fixture 'Ruby checks cannot export job outputs'
for output in 'UNKNOWN=value' 'sha<<EOF' 'pr_number=0' 'pr_number=-1' 'pr_number=12345678901' 'pr_number=01'; do
    reset_fixture
    printf 'sha=%s\npr_number=15\n%s\n' "$GITHUB_SHA" "$output" > "$PROTOCOL_FIXTURE/output"
    reject_fixture "host rejects verifier output $output" verify-merge
done
reset_fixture; printf 'sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\npr_number=15\n' > "$PROTOCOL_FIXTURE/output"; reject_fixture 'host rejects a different verifier SHA' verify-merge
reset_fixture; printf 'sha=%s\nsha=%s\npr_number=15\n' "$GITHUB_SHA" "$GITHUB_SHA" > "$PROTOCOL_FIXTURE/output"; reject_fixture 'host rejects duplicate verifier SHA' verify-merge
reset_fixture; printf 'sha=%s\n' "$GITHUB_SHA" > "$PROTOCOL_FIXTURE/output"; reject_fixture 'host rejects missing verifier PR number' verify-merge
reset_fixture; printf 'sha=%s\npr_number=15\000' "$GITHUB_SHA" > "$PROTOCOL_FIXTURE/output"; reject_fixture 'host rejects NUL in otherwise valid verifier output' verify-merge
reset_fixture; reject_fixture 'unknown operations fail before Docker starts' unknown
checks=$((checks + 1))
if [[ -s "$PROTOCOL_FIXTURE/called" ]]; then printf 'FAIL unknown operation launched Docker\n'; failures=$((failures + 1)); else printf 'ok   unknown operation never launched Docker\n'; fi

reset_fixture
printf 'QTMLEAP_ACTIONS_ROOT=%s\nQTMLEAP_ACTIONS_REVISION=%s' "$root" "$QTMLEAP_ACTIONS_REVISION" > "$PROTOCOL_FIXTURE/env"
bash "$root/runtime/docker-action.sh" ruby-check
printf 'host-env-seed\nQTMLEAP_ACTIONS_ROOT=%s\nQTMLEAP_ACTIONS_REVISION=%s\n' "$root" "$QTMLEAP_ACTIONS_REVISION" > "$temp/expected-env"
checks=$((checks + 1))
if cmp -s "$GITHUB_ENV" "$temp/expected-env" && cmp -s "$GITHUB_OUTPUT" "$temp/before-output"; then printf 'ok   valid Ruby metadata preserves the unterminated revision\n'; else printf 'FAIL valid Ruby metadata\n'; failures=$((failures + 1)); fi
reset_fixture
printf 'sha=%s\npr_number=15' "$GITHUB_SHA" > "$PROTOCOL_FIXTURE/output"
bash "$root/runtime/docker-action.sh" verify-merge
printf 'host-output-seed\nsha=%s\npr_number=15\n' "$GITHUB_SHA" > "$temp/expected-output"
checks=$((checks + 1))
if cmp -s "$GITHUB_ENV" "$temp/expected-env" && cmp -s "$GITHUB_OUTPUT" "$temp/expected-output"; then printf 'ok   valid verifier metadata preserves the unterminated PR number\n'; else printf 'FAIL valid verifier metadata\n'; failures=$((failures + 1)); fi
reset_fixture
unset QTMLEAP_ACTIONS_REVISION
bash "$root/runtime/docker-action.sh" ruby-check
checks=$((checks + 1))
if cmp -s "$GITHUB_ENV" "$temp/expected-env" && cmp -s "$GITHUB_OUTPUT" "$temp/before-output"; then printf 'ok   valid metadata works before a prior revision was exported\n'; else printf 'FAIL optional prior revision\n'; failures=$((failures + 1)); fi
export QTMLEAP_ACTIONS_REVISION=1111111111111111111111111111111111111111
reset_fixture
printf 'sha=%s\npr_number=9999999999\n' "$GITHUB_SHA" > "$PROTOCOL_FIXTURE/output"
bash "$root/runtime/docker-action.sh" verify-merge
printf 'host-output-seed\nsha=%s\npr_number=9999999999\n' "$GITHUB_SHA" > "$temp/expected-output"
checks=$((checks + 1))
if cmp -s "$GITHUB_ENV" "$temp/expected-env" && cmp -s "$GITHUB_OUTPUT" "$temp/expected-output"; then printf 'ok   verifier accepts the positive ten-digit PR bound\n'; else printf 'FAIL verifier PR bound\n'; failures=$((failures + 1)); fi
printf '%s protocol checks; %s failures\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
