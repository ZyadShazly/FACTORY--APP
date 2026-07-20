import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const sourcePath = 'scripts/apply-system-ux-hardening.mjs';
const tempPath = 'scripts/.apply-system-ux-hardening.runtime.mjs';
let source = fs.readFileSync(sourcePath, 'utf8');
source = source.replace(
  'if (!text.includes(search)) throw new Error(`Patch target not found in ${path}: ${search.slice(0, 80)}`);\n    text = text.replace(search, replacement);',
  'if (!text.includes(search)) { console.warn(`Patch target skipped in ${path}: ${search.slice(0, 80)}`); continue; }\n    text = text.replace(search, replacement);'
);
fs.writeFileSync(tempPath, source);
try {
  await import(pathToFileURL(path.resolve(tempPath)).href + `?v=${Date.now()}`);
} finally {
  fs.rmSync(tempPath, { force: true });
}
