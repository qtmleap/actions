import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
const inputs = {
  'ruby-check': ['command', 'working-directory'],
  'verify-merge': ['adapter', 'github-token', 'working-directory'],
  'apple-toolchain': ['xcode-version', 'developer-dir'],
  'setup-ruby': ['ruby-version', 'working-directory'],
  'repository-token': ['client-id', 'private-key', 'repository'],
  'run-adapter': ['adapter', 'operation', 'argv-json', 'working-directory'],
  'release-record': ['name', 'path', 'if-no-files-found'],
};
for (const [action, names] of Object.entries(inputs)) {
  const text = fs.readFileSync(`actions/${action}/action.yml`, 'utf8');
  const section = text.split('inputs:\n')[1].split(/^(?:outputs|runs):/m)[0];
  const declared = [...section.matchAll(/^  ([a-z-]+):$/gm)].map(match => match[1]);
  assert.deepEqual(declared, ['repo-root', ...(action === 'release-record' ? ['expected-source-sha'] : []), ...names], action);
  assert(text.includes('SHARED_REPO_ROOT: ${{ inputs.repo-root }}'));
  assert(text.includes('using: composite'));
  for (const match of text.matchAll(/^\s+uses: ([^\s#]+)/gm)) {
    assert(/@[0-9a-f]{40}$/.test(match[1]), `Unpinned nested action: ${match[1]}`);
  }
  assert(!text.includes('private-key: ${{ env.'), 'Protected key in environment');
}
const token = fs.readFileSync('actions/repository-token/action.yml', 'utf8');
assert(token.includes('permission-contents: read'));
assert(token.includes("skip-token-revoke: 'false'"));
assert(token.includes('match|QuantumLeap'));
const modules = fs.readdirSync('runtime/legacy').filter(name => name.endsWith('.rb'));
assert.equal(modules.length, 11);
for (const name of modules) {
  const text = fs.readFileSync(path.join('runtime/legacy', name), 'utf8');
  assert(!text.includes('require_relative "release_config"'));
  assert(!text.includes('__dir__'), 'Legacy runtime infers consumer root');
}
assert(!fs.existsSync('runtime/legacy/release_config.rb'));
const readme = fs.readFileSync('docs/consumer-contract.md', 'utf8');
for (const names of Object.values(inputs)) for (const name of names) assert(readme.includes('`' + name + '`'));
const records = fs.readFileSync('actions/release-record/action.yml', 'utf8');
assert(records.includes('SHARED_EXPECTED_SOURCE_SHA: ${{ inputs.expected-source-sha }}'));
assert(records.includes('default: ${{ github.sha }}'));
assert(records.includes('actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02'));
const workflow = fs.readFileSync('.github/workflows/shared-runtime.yaml', 'utf8');
assert(workflow.includes('runs-on: [self-hosted, Linux, X64, ubuntu-latest, docker]'));
assert(workflow.includes("if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository"));
assert(workflow.includes('rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 -color'));
assert(workflow.includes('run: bun tools/static-check.mjs'));
console.log('Static interface/pin/module/runner checks passed (not a YAML or Ruby syntax check)');
