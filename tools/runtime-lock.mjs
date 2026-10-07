import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const revision = process.argv[2];
if (!/^[0-9a-f]{40}$/.test(revision ?? '')) throw new Error('Supply full lowercase revision SHA (zeros for local tests only)');
function list(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const file = path.join(directory, entry.name);
    if (entry.isSymbolicLink()) throw new Error('Runtime symlink');
    if (entry.isDirectory()) return list(file);
    if (!entry.isFile()) throw new Error('Special runtime file');
    return [file];
  });
}
const runtime_files = Object.fromEntries(list(path.join(root, 'runtime')).sort().map(file =>
  [path.relative(root, file), crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')]));
console.log(JSON.stringify({ revision, runtime_files }, null, 2));
