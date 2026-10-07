#!/usr/bin/env bash
set -euo pipefail
version="${SHARED_RUBY_VERSION:?}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
ruby_bin="$HOME/.rbenv/versions/$version/bin"
[[ -x "$ruby_bin/ruby" && -x "$ruby_bin/gem" ]] || { printf '%s\n' 'Requested rbenv MRI is not installed' >&2; exit 1; }
[[ "$GITHUB_WORKSPACE" != *$'\n'* && "$RUNNER_TEMP" != *$'\n'* ]] || exit 1
export GITHUB_WORKSPACE="$(cd "$GITHUB_WORKSPACE" && pwd -P)"
export RUNNER_TEMP="$(cd "$RUNNER_TEMP" && pwd -P)"
case "$RUNNER_TEMP/" in "$GITHUB_WORKSPACE/"*) printf '%s\n' 'RUNNER_TEMP must be outside source' >&2; exit 1 ;; esac
export PATH="$ruby_bin:$PATH" RBENV_VERSION="$version"
root="$(cd "$SHARED_ACTION_PATH/../.." && pwd -P)"
export SHARED_ACTION_ROOT="$root"
app="$("$ruby_bin/ruby" -r "$root/runtime/bootstrap" -e 'print SharedCI::Bootstrap.app_root!')"
export SHARED_APP_ROOT="$app"
revision="$("$ruby_bin/ruby" -r "$root/runtime/bootstrap" -e 'app=ENV.fetch("SHARED_APP_ROOT"); revision=SharedCI::Bootstrap.lock!(app).fetch("revision"); expected=ENV["QTMLEAP_ACTIONS_REVISION"]; abort "Revision mismatch" if expected && expected != revision; SharedCI::Bootstrap.export!(root: ENV.fetch("SHARED_ACTION_ROOT"), app_root: app, revision: revision); print revision')"
export QTMLEAP_ACTIONS_REVISION="$revision"
work="$("$ruby_bin/ruby" -r "$root/runtime/actions" -e 'print SharedCI::Actions.inside_path(ENV.fetch("SHARED_APP_ROOT"), ENV.fetch("SHARED_WORKING_DIRECTORY", "."))')"
[[ "$("$ruby_bin/ruby" -e 'print RUBY_ENGINE + ":" + RUBY_VERSION')" == "ruby:$version" ]] || exit 1
# An independent cleanup adapter must retain a usable Ruby even if frozen install fails.
printf '%s\n' "$ruby_bin" >> "$GITHUB_PATH"
printf 'RBENV_VERSION=%s\nQTMLEAP_ACTIONS_ROOT=%s\nQTMLEAP_ACTIONS_REVISION=%s\n' "$version" "$root" "$revision" >> "$GITHUB_ENV"
locked="$("$ruby_bin/ruby" -e 's=File.read(ARGV.fetch(0)); v=s[/^BUNDLED WITH\n\s+([0-9]+\.[0-9]+\.[0-9]+)\s*\z/,1]; abort "Missing locked Bundler" unless v; print v' "$work/Gemfile.lock")"
owned="$(mktemp -d "$RUNNER_TEMP/shared-ruby.XXXXXX")"
export GEM_HOME="$owned/gems" GEM_PATH="$owned/gems" BUNDLE_PATH="$owned/bundle" BUNDLE_APP_CONFIG="$owned/config"
export BUNDLE_FROZEN=true BUNDLE_IGNORE_CONFIG=1
export FL_REPORT_PATH="$owned/fastlane-report" FASTLANE_SKIP_DOCS=true
mkdir -p "$FL_REPORT_PATH"
export PATH="$GEM_HOME/bin:$PATH"
# Do not inherit system/user Bundler configuration or dependency authorization.
"$ruby_bin/ruby" -r "$root/runtime/environment" -e 'env=SharedCI::Environment.child; env.merge!("BUNDLE_USER_CONFIG"=>File::NULL,"BUNDLE_USER_CACHE"=>ARGV[0]); abort "gem install failed" unless system(env, "gem", "install", "bundler", "--version", ARGV[1], "--no-document", unsetenv_others: true); abort "bundle install failed" unless system(env, "bundle", "_"+ARGV[1]+"_", "install", chdir: ARGV[2], unsetenv_others: true)' "$owned/cache" "$locked" "$work"
printf '%s\n' "$GEM_HOME/bin" >> "$GITHUB_PATH"
for key in RBENV_VERSION GEM_HOME GEM_PATH BUNDLE_PATH BUNDLE_APP_CONFIG BUNDLE_FROZEN BUNDLE_IGNORE_CONFIG FL_REPORT_PATH FASTLANE_SKIP_DOCS; do
  printf '%s=%s\n' "$key" "${!key}" >> "$GITHUB_ENV"
done
printf 'QTMLEAP_ACTIONS_ROOT=%s\nQTMLEAP_ACTIONS_REVISION=%s\n' "$root" "$revision" >> "$GITHUB_ENV"
