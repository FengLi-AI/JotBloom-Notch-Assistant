// Read-only working-tree triage. Reports paths/counts, never matched secret values.
// This is NOT a security audit or a Git-history scan.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const files = [];
function walk(relative) {
  const full = path.join(root, relative);
  if (!fs.existsSync(full)) return;
  for (const entry of fs.readdirSync(full, { withFileTypes: true })) {
    if (entry.name.startsWith('.')) continue;
    const item = path.join(relative, entry.name);
    if (entry.isDirectory()) walk(item);
    else if (entry.isFile() && /\.(swift|yml|plist|sh|mjs|txt)$/.test(entry.name)) files.push(item);
  }
}
for (const folder of ['JotBloom', 'JotBloomCore', 'JotBloomTests', 'scripts', 'release']) walk(folder);
for (const file of ['project.yml', 'README.md', '.gitignore']) if (fs.existsSync(path.join(root, file))) files.push(file);
const rules = [
  ['possible_provider_key', /\bsk-[A-Za-z0-9_-]{24,}\b/],
  ['possible_github_token', /\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b/],
  ['private_key_material', /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/],
  ['personal_home_path', /\/Users\/[A-Za-z0-9_.-]+\//],
];
const findings = [];
for (const file of files) {
  const lines = fs.readFileSync(path.join(root, file), 'utf8').split('\n');
  for (const [kind, pattern] of rules) {
    const numbers = lines.flatMap((line, index) => pattern.test(line) ? [index + 1] : []);
    if (numbers.length) findings.push({ file, kind, lines: numbers });
  }
}
const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8' }).trim();
const resources = [];
function assets(relative) {
  for (const entry of fs.readdirSync(path.join(root, relative), { withFileTypes: true })) {
    if (entry.name.startsWith('.')) continue;
    const item = path.join(relative, entry.name);
    if (entry.name.endsWith('.icns') || entry.name.endsWith('.appiconset')) resources.push(item);
    else if (entry.isDirectory()) assets(item);
  }
}
assets('JotBloom');
console.log(JSON.stringify({
  scope: 'current native sources, tests, scripts, release text and root configuration only',
  scannedFiles: files.length, findings,
  hasRootLicense: ['LICENSE', 'LICENSE.md', 'LICENSE.txt'].some(file => fs.existsSync(path.join(root, file))),
  appIconResources: resources,
  configuredRemoteCount: git('remote').split('\n').filter(Boolean).length,
  trackedFileCount: git('ls-files', '-z').split('\0').filter(Boolean).length,
  worktreeHasChanges: Boolean(git('status', '--porcelain')),
  excludedFromPublicByDefault: ['docs/', 'UI本地预览/', 'UI视觉生图/', 'artifacts/', 'agent-blueprint/'],
  notChecked: ['Git history', 'internal screenshots and logs', 'binary secret contents', 'third-party licence compatibility', 'macOS security acceptance'],
  publicReleaseReady: false,
  reason: 'Local triage only. Repository, licence, visual assets, public export and installation/security acceptance need confirmation.'
}, null, 2));
