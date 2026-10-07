#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${SHARED_ACTION_ROOT:-}" ]]; then
  root="$(cd -- "$SHARED_ACTION_ROOT" && pwd -P)"
else
  root="$(cd -- "${SHARED_ACTION_PATH:?}/../.." && pwd -P)"
fi
export SHARED_ACTION_ROOT="$root"
revision="$(ruby -r "$root/runtime/bootstrap" -e 'app=SharedCI::Bootstrap.app_root!; revision=SharedCI::Bootstrap.lock!(app).fetch("revision"); expected=ENV["QTMLEAP_ACTIONS_REVISION"]; abort "Revision mismatch" if expected && expected != revision; SharedCI::Bootstrap.export!(root: ENV.fetch("SHARED_ACTION_ROOT"), app_root: app, revision: revision); print revision')"
requested="${SHARED_XCODE_VERSION:?}"
[[ "$requested" =~ ^(26|27)(\.[0-9]+(\.[0-9]+)?)?$ ]] || exit 1
major="${requested%%.*}"
[[ "${SHARED_DEVELOPER_DIR:?}" == /* && "$SHARED_DEVELOPER_DIR" != *$'\n'* && "$SHARED_DEVELOPER_DIR" != *$'\r'* ]] || exit 1
export DEVELOPER_DIR="$SHARED_DEVELOPER_DIR"
[[ -d "$DEVELOPER_DIR" ]] || exit 1
# No host-wide xcode-select mutation, and no ambient credentials in probes.
probe() { env -i PATH="$PATH" DEVELOPER_DIR="$DEVELOPER_DIR" "$@"; }
[[ "$(probe uname -s)" == Darwin && "$(probe uname -m)" == arm64 ]] || exit 1
os="$(probe sw_vers -productVersion)"
[[ "$os" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && "${os%%.*}" == "$major" ]] || exit 1
actual="$(probe xcodebuild -version)"
first="${actual%%$'\n'*}"
version="${first#Xcode }"
[[ "$first" == "Xcode $version" && "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || exit 1
if [[ "$requested" == "$major" ]]; then
  [[ "${version%%.*}" == "$major" ]] || exit 1
else
  [[ "$version" == "$requested" ]] || exit 1
fi
sdk="$(probe xcrun --sdk iphoneos --show-sdk-version)"
[[ "$sdk" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && "${sdk%%.*}" == "$major" ]] || exit 1
printf 'DEVELOPER_DIR=%s\nQTMLEAP_ACTIONS_ROOT=%s\nQTMLEAP_ACTIONS_REVISION=%s\n' "$DEVELOPER_DIR" "$root" "$revision" >> "$GITHUB_ENV"
