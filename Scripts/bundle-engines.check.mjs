import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import vm from 'node:vm';
const js = await readFile(new URL('../Sources/LeafRender/Resources/leaf-engines.js', import.meta.url), 'utf8');
const context = vm.createContext({});
vm.runInContext(js, context, { timeout: 10_000 });
const e = context.LeafEngines;
assert.equal(vm.runInContext('typeof document', context), 'undefined');
const examples = [
  ['flowchart', 'flowchart LR\n A[Draft] --> B{Review}\n B --> C[Publish]'],
  ['sequence', 'sequenceDiagram\n Alice->>Bob: Hello\n Bob-->>Alice: Hi'],
  ['class', 'classDiagram\n Animal <|-- Cat\n Animal : +String name'],
  ['state', 'stateDiagram-v2\n [*] --> Draft\n Draft --> Published\n Published --> [*]'],
  ['er', 'erDiagram\n AUTHOR ||--o{ NOTE : writes\n AUTHOR { string name }'],
  ['pie', 'pie title Reading\n "Notes" : 60\n "Books" : 40'],
  ['mindmap', 'mindmap\n root((Leaf))\n  Write\n  Diagram'],
  ['gantt', 'gantt\n title Plan\n dateFormat YYYY-MM-DD\n section Work\n Draft :a, 2026-10-01, 3d'],
  ['gitGraph', 'gitGraph\n commit\n branch draft\n checkout draft\n commit\n checkout main\n merge draft'],
  ['timeline', 'timeline\n title Progress\n 2025 : Draft\n 2026 : Ship'],
  ['kanban', 'kanban\n todo[To do]\n  task[Write notes]'],
  ['journey', 'journey\n title Writing\n section Draft\n Write: 5: Author'],
  ['xychart', 'xychart-beta\n x-axis [Jan, Feb, Mar]\n y-axis "Pages" 0 --> 100\n bar [20, 50, 80]'],
  ['quadrantChart', 'quadrantChart\n title Priorities\n x-axis Low --> High\n y-axis Low --> High\n A: [0.3, 0.6]'],
  ['sankey', 'sankey-beta\n Source,Target,10'],
  ['packet', 'packet-beta\n 0-7: "Header"\n 8-15: "Data"'],
  ['treemap', 'treemap-beta\n "Writing"\n  "Notes": 40\n  "Books": 60'],
  ['block', 'block-beta\n columns 2\n A["Draft"] B["Publish"]\n A --> B'],
  ['architecture', 'architecture-beta\n group cloud(cloud)[Cloud]\n service db(database)[Store] in cloud'],
  ['requirement', 'requirementDiagram\n requirement readable {\n id: 1\n text: Preserve source\n }'],
  ['c4', 'C4Context\n Person(author, "Author")\n System(leaf, "Leaf")\n Rel(author, leaf, "Writes")'],
  ['agentflow', 'agentflow-beta TB\n flow writing["Writing"]\n draft["Draft"]@{ shape: task }\n review["Review"]@{ shape: decision }\n draft --> review\n end'],
  ['treeView', 'treeView-beta\n notes/\n  draft.md\n  publish.md'],
  ['cynefin', 'cynefin-beta\n title Writing\n clear\n  "Save the draft"\n complex\n  "Choose the story"'],
  ['wardley', 'wardley-beta\n title Notes\n anchor Writer [0.9, 0.6]\n component Editor [0.5, 0.7]\n Writer -> Editor'],
  ['eventmodeling', 'eventmodeling\n tf 01 ui Editor\n tf 02 cmd Save\n tf 03 evt Saved'],
  ['usecase', 'usecase-beta\n direction LR\n actor Author("Author")\n systemBoundary "Leaf"\n Write("Write note")\n end\n Author --> Write'],
  ['venn', 'venn-beta\n set Writing\n set Drawing\n union Writing,Drawing["Leaf"]'],
  ['ishikawa', 'ishikawa-beta\n Missing note\n Process\n  Not saved\n System\n  Wrong folder'],
  ['swimlane', 'swimlane-beta LR\n subgraph Author\n A[Draft]\n end\n subgraph Editor\n B[Review]\n end\n A --> B'],
  ['railroad', 'railroad-ebnf-beta\n title "Note"\n note = "draft" | "published" ;'],
  ['radar', 'radar-beta\n axis a["Writing"], b["Reading"], c["Drawing"]\n curve user["Author"]{80, 70, 60}\n max 100\n min 0'],
  ['info', 'info']
];
let count = 0;
const nativeCases = [];
for (const [type, source] of examples) {
  for (const theme of ['light', 'dark']) {
    const result = e.diagram(source, theme);
    assert.equal(result.error, undefined, `${type}: ${JSON.stringify(result.error)}`);
    assert.equal(result.type, type);
    assert(result.width > 0 && result.height > 0);
    assert(result.svg.startsWith('<svg'));
    assert(!/<[^>]*var\(/.test(result.svg), `${type} unresolved CSS`);
    assert(!result.svg.includes('<script'));
    nativeCases.push({ name: type + '-' + theme, ...result });
    count++;
  }
}
const literal = e.diagram('flowchart LR\n A["var(--literal)"] --> B[OK]');
assert(!literal.error);
assert(literal.svg.includes('var(--literal)'));
const invalid = e.diagram('flowchart LR\n A --> ');
assert(invalid.error && invalid.error.message.length);
assert.equal(e.diagram('not a diagram').error.code, 'unsupported-diagram');
assert.equal(e.diagram('flowchart LR\n' + 'A'.repeat(50_001)).error.code, 'limit');
const source = `---
title: Leaf
---
# Same heading
# Same heading

| Item | Value |
| --- | --- |
| Native | Yes |

- [x] Write
- [ ] Review

A note[^one], a [[Page|wiki link]], an ![[Embed]], ~~strike~~, ==mark==, and $x^2$.

> [!NOTE]
> Keep the source.

\`\`\`swift
let value = 42
\`\`\`

\`\`\`mermaid
flowchart LR
 A --> B
\`\`\`

$$
\\frac{1}{2}
$$

[^one]: Useful footnote.

<details><summary>More</summary>Static HTML.</details>

<Callout title="Details">
Static component content.
</Callout>

import Something from 'bad-module';

<script>globalThis.executed = true</script><img src="x" onerror="alert(1)">
<a href="javascript:alert(1)">Bad link</a>
`;
const options = { title: '<Leaf>', includeTOC: true, dark: true };
const doc = e.document(source, options, '/* bundled math */');
assert.equal(doc.error, undefined, JSON.stringify(doc.error));
for (const wanted of ['<table>', 'type="checkbox"', 'footnotes', 'leaf-wiki-link', 'leaf-embed-link', '<del>', '<mark>', 'katex', 'hljs-keyword', 'leaf-diagram', '<details>', 'leaf-component', 'leaf-inert-source', 'leaf-callout', 'same-heading-1', 'Table of contents']) assert(doc.html.includes(wanted), `Missing ${wanted}`);
for (const unwanted of ['<script>', 'onerror=', 'href="javascript:', 'src="https:', 'url(fonts/', 'undefined</']) assert(!doc.html.includes(unwanted), `Unsafe/unresolved ${unwanted}`);
assert(doc.html.includes("script-src 'none'"));
assert(doc.html.includes('&lt;Leaf&gt;'));
assert.equal(context.executed, undefined);
assert(!e.fragment('[file](file:///tmp/test.md) [wiki](leaf://open)').html.includes('href=""'));
assert(e.fragment('![local](local%20image.png) [relative](note.md)').html.includes('src="local%20image.png"'));
assert(e.fragment('[relative](note.md)').html.includes('href="note.md"'));
const styledHTML = e.fragment('<div style="color:red;padding:16px;border-radius:8px;background-image:url(https://example.com/remote);position:fixed">Styled HTML</div>').html;
assert(styledHTML.includes('color:red') && styledHTML.includes('padding:16px') && styledHTML.includes('border-radius:8px'));
assert(!styledHTML.includes('background-image') && !styledHTML.includes('https://example.com/remote') && !styledHTML.includes('position:fixed'));
assert(!e.fragment('[bad](javascript&#58;alert(1))').html.includes('javascript:'));
assert.equal(e.fragment('Plain **text**.').html.trim(), '<p>Plain <strong>text</strong>.</p>');
assert(!e.fragment('[^a\" onmouseover=\"evil]: Text\n\nHello[^a\" onmouseover=\"evil].').html.includes(' onmouseover='));
const css = await readFile(new URL('../Sources/LeafRender/Resources/leaf-math.css', import.meta.url), 'utf8');
assert(css.includes('data:font/woff2;base64,'));
assert(!/url\((?!data:)/.test(css));
await writeFile('/tmp/leaf-render-probe.html', doc.html.replace('/* bundled math */', css));
await writeFile('/tmp/leaf-render-probe.svg', e.diagram(examples[0][1]).svg);
await writeFile('/tmp/leaf-render-native-cases.json', JSON.stringify(nativeCases));
console.log(`PASS: ${count} Mermaid theme cases, native CSS resolution, malformed/oversized input, GFM, footnotes, math, highlighting, wiki links, callouts, static MDX/HTML, script and URL safety, offline fonts.`);
