#!/usr/bin/env bash
# CI entry point for the guarded TestFlight lane. Keeps every generated file under RUNNER_TEMP and
# runs the cleanup helper on every exit path. Refuses to run outside GitHub Actions on a runner.
set -euo pipefail
umask 077

if [[ "${GITHUB_ACTIONS:-}" != "true" || -z "${RUNNER_TEMP:-}" ]]; then
    echo "This script runs only in GitHub Actions." >&2
    exit 2
fi
project_dir=$(cd -- "${1:?An explicit app root is required}" && pwd -P)
cd "$project_dir"

export RELEASE_WORK="$RUNNER_TEMP/release-work"
# fastlane would otherwise write report.xml and regenerate README.md inside the checkout.
export FL_REPORT_PATH="$RUNNER_TEMP/release-fastlane-report"
export FASTLANE_SKIP_DOCS=1 FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_SKIP_WELCOME=1 FASTLANE_HIDE_CHANGELOG=1
export FASTLANE_OPT_OUT_USAGE=YES CI=true
/usr/bin/env -i PATH="${PATH:?}" mkdir -p "$FL_REPORT_PATH"

status=0
bundle exec fastlane ios beta || status=$?
cleanup=0
/usr/bin/env -i HOME="${HOME:?}" PATH="${PATH:?}" RUNNER_TEMP="$RUNNER_TEMP" RELEASE_WORK="$RELEASE_WORK" \
    bash "$(dirname -- "${BASH_SOURCE[0]}")/ci-release-cleanup.sh" || cleanup=$?
/usr/bin/env -i PATH="${PATH:?}" rm -rf "$FL_REPORT_PATH"
if [[ "$status" -ne 0 ]]; then exit "$status"; fi
exit "$cleanup"
