#!/usr/bin/env bash
# Offline shell behavior tests. Every Apple/Docker/Ruby command is a local fake.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Offline text checks supplement (not replace) Bun/YAML/actionlint validation.
for action in ruby-check verify-merge apple-toolchain setup-ruby repository-token run-adapter release-record; do
  text="$(< "$root/actions/$action/action.yml")"
  [[ "$text" == *'  repo-root:'* && "$text" == *'SHARED_REPO_ROOT: ${{ inputs.repo-root }}'* ]]
done
text="$(< "$root/actions/release-record/action.yml")"
[[ "$text" == *'default: ${{ github.sha }}'* && "$text" == *'SHARED_EXPECTED_SOURCE_SHA: ${{ inputs.expected-source-sha }}'* ]]
[[ "$text" == *'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02'* ]]
text="$(< "$root/.github/workflows/shared-runtime.yaml")"
[[ "$text" == *'runs-on: [self-hosted, Linux, X64, ubuntu-latest, docker]'* ]]
[[ "$text" == *"if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository"* ]]
[[ "$text" == *'rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 -color'* && "$text" == *'run: bun tools/static-check.mjs'* ]]
temp="$(mktemp -d)"
temp="$(cd "$temp" && pwd -P)"
trap 'rm -rf "$temp"' EXIT
mkdir -p "$temp/bin" "$temp/workspace/Kotatsu" "$temp/runner" "$temp/developer"
bin="$temp/bin"
export PATH="$bin:$PATH"
export SHARED_ACTION_PATH="$root/actions/apple-toolchain"
export GITHUB_WORKSPACE="$temp/workspace" RUNNER_TEMP="$temp/runner" SHARED_REPO_ROOT=Kotatsu
export GITHUB_ENV="$temp/exported" GITHUB_OUTPUT="$temp/output"
export SHARED_DEVELOPER_DIR="$temp/developer" SHARED_XCODE_VERSION=26
export SSH_AUTH_SOCK=sentinel AMBIENT_SECRET=sentinel BUNDLE_GITHUB__COM=sentinel
printf '%s\n' Darwin > "$temp/os"
printf '%s\n' arm64 > "$temp/arch"
printf '%s\n' 26.1 > "$temp/macos"
printf '%s\n' 26.2 > "$temp/xcode"
printf '%s\n' 26.1 > "$temp/sdk"
# This fake only supplies bootstrap's revision. Ruby suites test the real resolver.
cat > "$bin/ruby" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == *'SharedCI::Bootstrap.app_root!'* && "$SHARED_REPO_ROOT" == Kotatsu ]]
printf '%040d' 0
SH
chmod +x "$bin/ruby"
for cmd in uname sw_vers xcodebuild xcrun; do
  printf '#!/usr/bin/env bash\nset -euo pipefail\nstate=%q\n' "$temp" > "$bin/$cmd"
  cat >> "$bin/$cmd" <<'SH'
[[ -z "${SSH_AUTH_SOCK:-}" && -z "${AMBIENT_SECRET:-}" && -z "${BUNDLE_GITHUB__COM:-}" ]]
[[ "$DEVELOPER_DIR" == "$state/developer" ]]
name="${0##*/}"
printf '%s %s\n' "$name" "$*" >> "$state/probes"
case "$name $*" in
  'uname -s') IFS= read -r value < "$state/os"; printf '%s\n' "$value" ;;
  'uname -m') IFS= read -r value < "$state/arch"; printf '%s\n' "$value" ;;
  'sw_vers -productVersion') IFS= read -r value < "$state/macos"; printf '%s\n' "$value" ;;
  'xcodebuild -version') IFS= read -r value < "$state/xcode"; printf 'Xcode %s\nBuild version FAKE\n' "$value" ;;
  'xcrun --sdk iphoneos --show-sdk-version') IFS= read -r value < "$state/sdk"; printf '%s\n' "$value" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$bin/$cmd"
done
printf '#!/usr/bin/env bash\nexit 99\n' > "$bin/xcode-select"
chmod +x "$bin/xcode-select"
run_toolchain() { bash "$root/runtime/apple-toolchain.sh"; }
reject_toolchain() {
  : > "$GITHUB_ENV"
  if run_toolchain; then printf '%s\n' 'Expected toolchain rejection' >&2; exit 1; fi
  [[ ! -s "$GITHUB_ENV" ]]
}
run_toolchain
[[ -s "$GITHUB_ENV" ]]
SHARED_XCODE_VERSION=26.2 run_toolchain
SHARED_XCODE_VERSION=26.1 reject_toolchain
SHARED_XCODE_VERSION=26.2.1 reject_toolchain
printf '%s\n' 27.0 > "$temp/sdk"; reject_toolchain
printf '%s\n' 26.1 > "$temp/sdk"
printf '%s\n' 27.0 > "$temp/macos"; reject_toolchain
printf '%s\n' 26.1 > "$temp/macos"
printf '%s\n' x86_64 > "$temp/arch"; reject_toolchain
printf '%s\n' arm64 > "$temp/arch"
printf '%s\n' Linux > "$temp/os"; reject_toolchain
printf '%s\n' Darwin > "$temp/os"
printf '%s\n' 27.0 > "$temp/xcode"; reject_toolchain
printf '%s\n' 27.0 > "$temp/sdk"
printf '%s\n' 27.0 > "$temp/macos"
SHARED_XCODE_VERSION=27 run_toolchain
SHARED_XCODE_VERSION=27.0 run_toolchain
SHARED_XCODE_VERSION=27.1 reject_toolchain
# Fake Docker inspects actual launch argv and writes to the actual owned mount.
printf '#!/usr/bin/env bash\nset -euo pipefail\nstate=%q\n' "$temp" > "$bin/docker"
cat >> "$bin/docker" <<'SH'
args=" $* "
[[ "$args" == *' --env GEM_HOME=/output/gems '* ]]
if [[ "$args" != *' --env GEM_PATH=/output/gems:/usr/local/lib/ruby/gems/3.4.0 '* ]]; then exit 24; fi
[[ "$args" == *' --env PATH=/output/gems/bin:'* && "$args" == *' --env SHARED_REPO_ROOT '* ]]
if [[ "$args" != *' --tmpfs /tmp:rw,exec,nosuid,nodev '* ]]; then exit 23; fi
[[ "$SHARED_REPO_ROOT" == Kotatsu ]]
out=''
for arg in "$@"; do
  if [[ "$arg" == type=bind,source=*,target=/output ]]; then
    out="${arg#type=bind,source=}"; out="${out%,target=/output}"
  fi
done
[[ "$out" == "$state/runner/"* && -d "$out/gems/bin" ]]
: > "$out/gems/writable"
[[ "$args" == *' readonly '* || "$args" == *',readonly '* ]]
[[ "$args" == *' ruby /shared/runtime/actions.rb ruby-check '* ]]
printf '%s\n' 'fake-docker-gem-home-writable' >> "$state/docker-checked"
SH
chmod +x "$bin/docker"
export SHARED_ACTION_PATH="$root/actions/ruby-check" SHARED_COMMAND='gem install ./local.gem --local --no-document'
bash "$root/runtime/docker-action.sh" ruby-check
[[ -s "$temp/docker-checked" ]]
printf '%s\n' 'Offline toolchain/environment/Docker launcher regressions passed (fake commands only)'
