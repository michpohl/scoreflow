#!/usr/bin/env node
import { chmod, copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const root = new URL('../', import.meta.url);
const output = new URL('assets/www/transcription/', root);
await mkdir(output, { recursive: true });

await build({
  entryPoints: [fileURLToPath(new URL('tools/transcribe_pcm.mjs', root))],
  outfile: fileURLToPath(new URL('basic_pitch.bundle.js', output)),
  bundle: true,
  minify: true,
  format: 'iife',
  platform: 'browser',
  target: ['chrome90', 'safari15'],
  legalComments: 'linked',
});

const spotify = new URL('node_modules/@spotify/basic-pitch/', root);
const wasm = new URL('node_modules/@tensorflow/tfjs-backend-wasm/dist/', root);
const dependencyLicenses = [
  'long/LICENSE',
  'node-fetch/LICENSE.md',
  'string_decoder/LICENSE',
  'midi-file/LICENSE.md',
  '@tonejs/midi/LICENSE.md',
  'array-flatten/LICENSE',
];
const licenses = await Promise.all(dependencyLicenses.map(async path => {
  const contents = await readFile(new URL(`node_modules/${path}`, root), 'utf8');
  return `${path}\n\n${contents.trim()}`;
}));
const seedrandom = await readFile(new URL('node_modules/seedrandom/seedrandom.js', root), 'utf8');
const alea = await readFile(new URL('node_modules/seedrandom/lib/alea.js', root), 'utf8');
licenses.push(
  `seedrandom/seedrandom.js\n\n${seedrandom.slice(0, seedrandom.indexOf('*/') + 2)}`,
  `seedrandom/lib/alea.js\n\n${alea.slice(0, alea.indexOf('(function')).trim()}`,
);
const licenseText = licenses.join('\n\n---\n\n')
  .replace(/\r\n/g, '\n')
  .replace(/[ \t]+$/gm, '');

await Promise.all([
  copyFile(new URL('LICENSE', spotify), new URL('Apache-2.0.txt', output)),
  writeFile(new URL('Third-Party-Licenses.txt', output), licenseText + '\n'),
  ...['model.json', 'group1-shard1of1.bin'].map(name =>
    copyFile(new URL(`model/${name}`, spotify), new URL(name, output))),
  ...['tfjs-backend-wasm.wasm', 'tfjs-backend-wasm-simd.wasm'].map(async name => {
    const destination = new URL(name, output);
    await copyFile(new URL(name, wasm), destination);
    await chmod(destination, 0o644);
  }),
]);
