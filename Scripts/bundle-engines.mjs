import { build } from 'esbuild';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { createHash } from 'node:crypto';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const resources = path.join(root, 'Sources/LeafRender/Resources');
const licenses = path.join(root, 'Licenses/LeafRender');
await mkdir(resources, { recursive: true });
await mkdir(licenses, { recursive: true });
await build({
  entryPoints: [path.join(root, 'Scripts/bundle-engines.entry.js')],
  outfile: path.join(resources, 'leaf-engines.js'), bundle: true, format: 'iife',
  globalName: 'LeafEngines', target: 'es2022', platform: 'browser',
  minify: true, legalComments: 'none', charset: 'utf8', logLevel: 'warning'
});
// Inline only WOFF2 fonts. No font network access or installation is needed.
let css = await readFile(path.join(root, 'node_modules/katex/dist/katex.min.css'), 'utf8');
const fontURLs = [...new Set([...css.matchAll(/url\(([^)]+)\)/g)].map(m => m[1].replace(/["']/g, '')))];
for (const url of fontURLs) {
  if (!url.endsWith('.woff2')) continue;
  const data = await readFile(path.join(root, 'node_modules/katex/dist', url));
  css = css.split(`url(${url})`).join(`url(data:font/woff2;base64,${data.toString('base64')})`);
}
css = css.replace(/,url\([^)]*\) format\("(?:woff|truetype)"\)/g, '');
if (/url\((?!data:)/.test(css)) throw new Error('Unbundled math font URL.');
await writeFile(path.join(resources, 'leaf-math.css'), css);
const packages = ['pele', 'marked', 'marked-footnote', 'highlight.js', 'katex', 'xss', 'cssfilter'];
const manifest = [];
let combined = 'Leaf rendering dependencies\n\n';
for (const name of packages) {
  const base = path.join(root, 'node_modules', name);
  const pkg = JSON.parse(await readFile(path.join(base, 'package.json'), 'utf8'));
  let license;
  try { license = await readFile(path.join(base, 'LICENSE'), 'utf8'); }
  catch { license = await readFile(path.join(licenses, `${name}.txt`), 'utf8'); }
  await writeFile(path.join(licenses, `${name}.txt`), license);
  combined += `${name} ${pkg.version}\n${pkg.repository?.url ?? pkg.repository ?? ''}\n\n${license}\n\n`;
  manifest.push({ name, version: pkg.version, license: pkg.license, source: pkg.repository?.url ?? pkg.repository });
}
await writeFile(path.join(resources, 'ThirdPartyNotices.txt'), combined);
const engine = await readFile(path.join(resources, 'leaf-engines.js'));
const fonts = await readFile(path.join(resources, 'leaf-math.css'));
await writeFile(path.join(licenses, 'manifest.json'), JSON.stringify({
  dependencies: manifest,
  generated: {
    'leaf-engines.js': { bytes: engine.length, sha256: createHash('sha256').update(engine).digest('hex') },
    'leaf-math.css': { bytes: fonts.length, sha256: createHash('sha256').update(fonts).digest('hex') }
  }
}, null, 2) + '\n');
console.log(`Bundled offline renderers (${engine.length.toLocaleString()} bytes), math fonts (${fonts.length.toLocaleString()} bytes), and ${packages.length} license notices.`);
