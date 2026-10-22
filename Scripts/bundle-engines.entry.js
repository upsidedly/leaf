import { Marked } from 'marked';
import footnote from 'marked-footnote';
import hljs from 'highlight.js';
import katex from 'katex';
import * as pele from 'pele';
import xss from 'xss';

const escape = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const themes = {
  light: { bg: '#ffffff', fg: '#242424', muted: '#707070', line: '#555555', surface: '#f5f5f5', 'surface-alt': '#eaeaea', border: '#b0b0b0', accent: '#4b78b7' },
  dark: { bg: '#1e1e1e', fg: '#e8e8e8', muted: '#aaaaaa', line: '#bfbfbf', surface: '#2b2b2b', 'surface-alt': '#393939', border: '#777777', accent: '#8aafd9' }
};

// AppKit's SVG decoder does not implement CSS custom properties. Resolve them in
// markup attributes only, preserving literal var(...) text in diagram labels.
function nativeSVG(svg, dark) {
  const definitions = Object.create(null);
  for (const tag of svg.matchAll(/<[^>]*>/g)) {
    for (const style of tag[0].matchAll(/\bstyle="([^"]*)"/g)) {
      style[1].replace(/--([\w-]+)\s*:\s*([^;]+)/g, (_, key, value) => { definitions[key] = value; return ''; });
    }
  }
  for (const [key, value] of Object.entries(themes[dark ? 'dark' : 'light'])) definitions[`pele-${key}`] = value;
  definitions['pele-font'] = 'Helvetica Neue, Helvetica, Arial, sans-serif';
  definitions['pele-font-mono'] = 'Menlo, monospace';
  definitions['pele-radius'] = '5px';
  function resolve(text, depth = 0) {
    if (depth > 20) throw new Error('Diagram theme variables are nested too deeply.');
    let result = '', at = 0;
    while (at < text.length) {
      const start = text.indexOf('var(', at);
      if (start < 0) return result + text.slice(at);
      result += text.slice(at, start);
      let end = start + 4, nesting = 1, comma = -1;
      for (; end < text.length && nesting; end++) {
        const c = text[end];
        if (c === '(') nesting++;
        else if (c === ')') nesting--;
        else if (c === ',' && nesting === 1 && comma < 0) comma = end;
      }
      if (nesting) throw new Error('The diagram contains an incomplete theme variable.');
      const name = text.slice(start + 4, comma >= 0 ? comma : end - 1).trim().replace(/^--/, '');
      const replacement = definitions[name] ?? (comma >= 0 ? text.slice(comma + 1, end - 1).trim() : undefined);
      if (replacement === undefined) throw new Error(`The diagram uses an unknown theme variable: ${name}.`);
      result += resolve(replacement, depth + 1);
      at = end;
    }
    return result;
  }
  return svg.replace(/<[^>]*>/g, tag => tag.replace(/\b(style|fill|stroke|color|font-[\w-]+|rx|ry|opacity|stroke-[\w-]+)="([^"]*)"/g, (_, name, value) => `${name}="${resolve(value)}"`));
}

function renderDiagram(source, dark = false) {
  const result = pele.render(source, {
    fontFamily: 'Helvetica Neue, Helvetica, Arial, sans-serif',
    fontFamilyMono: 'Menlo, monospace', responsive: false, autoDirection: false,
    limit: 50_000, outputLimit: 4_000_000, maxEdges: 5_000, links: false, images: false
  });
  return { svg: nativeSVG(result.svg, dark), width: result.width, height: result.height, type: result.type };
}

const allowed = { ...xss.whiteList };
for (const tag of ['div', 'span', 'section', 'article', 'aside', 'header', 'footer', 'nav', 'details', 'summary', 'figure', 'figcaption', 'mark', 'kbd', 'samp', 'sub', 'sup', 'abbr', 'dl', 'dt', 'dd']) allowed[tag] ??= [];
allowed.input = ['type', 'checked', 'disabled'];
allowed.img = ['src', 'alt', 'title', 'width', 'height', 'loading'];
allowed.a = ['href', 'title', 'name', 'id', 'target', 'rel'];
allowed.details = ['open'];
for (const tag of Object.keys(allowed)) allowed[tag] = [...new Set([...allowed[tag], 'style'])];
const formattingStyles = Object.fromEntries([
  'color', 'background-color', 'font-family', 'font-size', 'font-weight', 'font-style',
  'line-height', 'letter-spacing', 'text-align', 'text-decoration', 'text-transform',
  'white-space', 'word-break', 'overflow-wrap', 'vertical-align',
  'margin', 'margin-top', 'margin-right', 'margin-bottom', 'margin-left',
  'padding', 'padding-top', 'padding-right', 'padding-bottom', 'padding-left',
  'border', 'border-top', 'border-right', 'border-bottom', 'border-left',
  'border-color', 'border-style', 'border-width', 'border-radius', 'border-collapse',
  'width', 'height', 'max-width', 'max-height', 'min-width', 'min-height',
  'display', 'flex-direction', 'flex-wrap', 'justify-content', 'align-items',
  'gap', 'row-gap', 'column-gap', 'grid-template-columns', 'grid-template-rows'
].map(name => [name, true]));
const sanitizer = new xss.FilterXSS({
  whiteList: allowed,
  stripIgnoreTag: false,
  allowCommentTag: false,
  css: { whiteList: formattingStyles },
  onIgnoreTagAttr(tag, name, value) {
    if (/^(?:class|id|title|role|aria-[\w-]+|data-[\w-]+)$/.test(name)) return `${name}="${escape(value)}"`;
    return '';
  },
  safeAttrValue(tag, name, value, cssFilter) {
    if (name === 'href' || name === 'src') {
      const decoded = xss.friendlyAttrValue(value).trim();
      const compact = decoded.replace(/[\u0000-\u0020\u007f-\u009f]+/g, '');
      const scheme = /^([a-z][a-z\d+.-]*):/i.exec(compact)?.[1].toLowerCase();
      if (scheme && !['http', 'https', 'mailto', 'tel', 'file', 'leaf'].includes(scheme)) return '';
      if (/^(?:\\\\|\/\/)/.test(compact)) return '';
      if (!scheme || ['file', 'leaf'].includes(scheme)) return escape(decoded);
    }
    if ((name === 'href' || name === 'src') && /^(?:file|leaf):/i.test(value)) return escape(value);
    if (tag === 'input' && name === 'type') return value === 'checkbox' ? 'checkbox' : '';
    return xss.safeAttrValue(tag, name, value, cssFilter);
  }
});

function safeHTML(source) {
  // Inert source survives visibly. No custom component, expression, import or
  // document script is ever evaluated in either JavaScriptCore or the preview.
  return sanitizer.process(source.replace(/\bclassName\s*=/g, 'class='));
}

function staticMDX(source) {
  let fence = null;
  const lines = source.replace(/\r\n?/g, '\n').split('\n');
  for (let i = 0; i < lines.length; i++) {
    const match = /^\s*(`{3,}|~{3,})/.exec(lines[i]);
    if (match) {
      if (!fence) fence = match[1][0]; else if (match[1][0] === fence) fence = null;
      continue;
    }
    if (fence) continue;
    if (/^\s*(?:import\s|export\s)/.test(lines[i])) {
      const held = [lines[i]];
      while (i + 1 < lines.length && !/[;}]\s*$/.test(held.at(-1)) && /^\s*(?:[\w{*,'"} \t]+|from\s.*)\s*$/.test(lines[i + 1]) && held.length < 20) held.push(lines[++i]);
      lines[i] = `<pre class="leaf-inert-source" title="MDX module code is shown as source"><code>${escape(held.join('\n'))}</code></pre>`;
      for (let j = i - held.length + 1; j < i; j++) lines[j] = '';
    } else if (/^\s*<\/?[A-Z]/.test(lines[i])) {
      lines[i] = lines[i].replace(/<(\/?)([A-Z][\w.]*)\b([^>]*?)(\/?)>/g, (_, close, name, attrs, selfClose) => {
        const label = /\b(?:title|label)\s*=\s*["']([^"']*)["']/.exec(attrs)?.[1] ?? name;
        if (close) return '</section>';
        if (selfClose) return `<section class="leaf-component"><span class="leaf-component-label">${escape(label)}</span></section>`;
        return `<section class="leaf-component" data-component="${escape(name)}"><span class="leaf-component-label">${escape(label)}</span>`;
      });
    }
  }
  return lines.join('\n');
}

function plainText(html) { return html.replace(/<[^>]*>/g, '').replace(/&(?:amp|lt|gt|quot|#39);/g, m => ({ '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'" })[m]); }
function slug(text) { return plainText(text).toLowerCase().normalize('NFKC').replace(/[^\p{L}\p{N}\s_-]/gu, '').trim().replace(/\s+/g, '-') || 'section'; }
function math(tex, display) {
  try { return katex.renderToString(tex, { displayMode: display, throwOnError: true, trust: false, strict: 'ignore', maxExpand: 1000, maxSize: 50, output: 'htmlAndMathml' }); }
  catch (error) { return `<span class="leaf-render-error" title="${escape(error.message)}"><code>${escape(tex)}</code></span>`; }
}

function renderMarkup(source, dark = false) {
  const headings = [], slugs = new Map();
  const parser = new Marked({ gfm: true, breaks: false, pedantic: false });
  parser.use(footnote({ description: 'Footnotes', sectionClass: 'footnotes', headingClass: 'sr-only', backRefLabel: 'Back to reference' }));
  parser.use({
    renderer: {
      heading({ tokens, depth }) {
        const text = this.parser.parseInline(tokens), base = slug(text), count = slugs.get(base) ?? 0;
        slugs.set(base, count + 1);
        const anchor = count ? `${base}-${count}` : base;
        headings.push({ title: plainText(text), level: depth, anchor });
        return `<h${depth} id="${escape(anchor)}">${text}</h${depth}>\n`;
      },
      html({ text }) { return safeHTML(text); },
      link({ href, title, tokens }) {
        return safeHTML(`<a href="${escape(href)}"${title ? ` title="${escape(title)}"` : ''}>`) + this.parser.parseInline(tokens) + '</a>';
      },
      image({ href, title, text }) {
        return safeHTML(`<img src="${escape(href)}" alt="${escape(text)}" loading="lazy"${title ? ` title="${escape(title)}"` : ''}>`);
      },
      code({ text, lang }) {
        const language = (lang ?? '').trim().split(/\s/)[0].toLowerCase();
        if (language === 'mermaid') {
          try {
            const result = renderDiagram(text, dark);
            return `<figure class="leaf-diagram" data-diagram="${escape(result.type)}">${result.svg}</figure>\n`;
          } catch (error) {
            return `<figure class="leaf-diagram-error"><figcaption>${escape(error.message)}</figcaption><pre><code class="language-mermaid">${escape(text)}</code></pre></figure>\n`;
          }
        }
        if (['math', 'latex', 'tex'].includes(language)) return `<div class="leaf-math">${math(text, true)}</div>\n`;
        let body = escape(text);
        if (text.length <= 100_000 && language && hljs.getLanguage(language)) {
          try { body = hljs.highlight(text, { language, ignoreIllegals: true }).value; } catch {}
        }
        return `<pre><code class="hljs${language ? ` language-${escape(language)}` : ''}">${body}</code></pre>\n`;
      },
      blockquote({ tokens }) {
        let body = this.parser.parse(tokens);
        const callout = /^<p>\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION|ABSTRACT|INFO|SUCCESS|QUESTION|FAILURE|DANGER|BUG|EXAMPLE|QUOTE)\](?:[+-])?[ \t]*([^<\n]*)(\n|<\/p>\s*)/i.exec(body);
        if (!callout) return `<blockquote>\n${body}</blockquote>\n`;
        body = body.slice(callout[0].length);
        if (callout[3] === '\n' && !body.startsWith('<')) body = '<p>' + body;
        return `<aside class="leaf-callout leaf-callout-${callout[1].toLowerCase()}"><p class="leaf-callout-title">${escape(callout[2]?.trim() || callout[1].toLowerCase().replace(/^./, c => c.toUpperCase()))}</p><div>${body}</div></aside>\n`;
      }
    },
    extensions: [
      {
        name: 'leafBlockMath', level: 'block', start: source => source.indexOf('$$'),
        tokenizer(source) {
          const match = /^\$\$[ \t]*\n([\s\S]+?)\n\$\$[ \t]*(?:\n|$)/.exec(source) ?? /^\$\$([^\n]+?)\$\$[ \t]*(?:\n|$)/.exec(source);
          if (match) return { type: 'leafBlockMath', raw: match[0], text: match[1] };
        }, renderer: token => `<div class="leaf-math">${math(token.text, true)}</div>\n`
      },
      {
        name: 'leafInlineMath', level: 'inline', start: source => source.indexOf('$'),
        tokenizer(source) {
          const match = /^\$(?![\s$])((?:\\.|[^$\n])+?)(?<!\s)\$(?!\d)/.exec(source);
          if (match) return { type: 'leafInlineMath', raw: match[0], text: match[1] };
        }, renderer: token => math(token.text, false)
      },
      {
        name: 'leafWiki', level: 'inline', start: source => { const i = source.indexOf('[['); return i > 0 && source[i - 1] === '!' ? i - 1 : i; },
        tokenizer(source) {
          const match = /^(!?)\[\[([^\]\n]+)\]\]/.exec(source);
          if (match) return { type: 'leafWiki', raw: match[0], embed: Boolean(match[1]), target: match[2].split('|')[0], label: match[2].split('|').slice(1).join('|') || match[2].split('|')[0] };
        }, renderer: token => `<a class="${token.embed ? 'leaf-embed-link' : 'leaf-wiki-link'}" href="leaf://open?target=${escape(encodeURIComponent(token.target))}">${escape(token.label)}</a>`
      },
      {
        name: 'leafHighlight', level: 'inline', start: source => source.indexOf('=='),
        tokenizer(source) { const match = /^==([^=\n](?:[^\n]*?[^=\n])?)==/.exec(source); if (match) return { type: 'leafHighlight', raw: match[0], text: match[1] }; },
        renderer(token) { return `<mark>${escape(token.text)}</mark>`; }
      }
    ]
  });
  const prepared = staticMDX(source);
  const frontmatter = /^---\n([\s\S]*?)\n---[ \t]*(?:\n|$)/.exec(prepared);
  const content = frontmatter ? prepared.slice(frontmatter[0].length) : prepared;
  let html = parser.parse(content);
  if (frontmatter) html = `<details class="leaf-frontmatter"><summary>Properties</summary><pre><code>${escape(frontmatter[1])}</code></pre></details>\n` + html;
  return { html, headings };
}

function safeFont(font, fallback) {
  const value = String(font ?? fallback);
  return /^[\p{L}\p{N}\s,'"._-]{1,160}$/u.test(value) ? value : fallback;
}
function number(value, fallback, min, max) { return Number.isFinite(value) ? Math.min(max, Math.max(min, value)) : fallback; }
function documentHTML(source, options, mathCSS) {
  const dark = Boolean(options.dark), result = renderMarkup(source, dark);
  const bodyFont = safeFont(options.bodyFont, 'system-ui'), codeFont = safeFont(options.codeFont, 'ui-monospace');
  const fontSize = number(options.fontSize, 16, 10, 40), lineHeight = number(options.lineHeight, 1.65, 1, 3), width = number(options.contentWidth, 760, 320, 2400);
  const colors = dark ? { bg: '#1e1e1e', fg: '#e4e4e4', muted: '#a4a4a4', border: '#414141', fill: '#292929', link: '#9bbfe3', mark: '#665520' } : { bg: '#ffffff', fg: '#292929', muted: '#747474', border: '#dddddd', fill: '#f6f6f6', link: '#376fa6', mark: '#fff1a8' };
  const toc = options.includeTOC && result.headings.length ? `<nav class="leaf-toc" aria-label="Table of contents"><p>Contents</p><ol>${result.headings.map(h => `<li class="toc-level-${h.level}"><a href="#${escape(h.anchor)}">${escape(h.title)}</a></li>`).join('')}</ol></nav>` : '';
  const css = `:root{color-scheme:${dark ? 'dark' : 'light'};--bg:${colors.bg};--fg:${colors.fg};--muted:${colors.muted};--border:${colors.border};--fill:${colors.fill};--link:${colors.link}}
*{box-sizing:border-box}html{background:var(--bg);color:var(--fg);scroll-behavior:auto}body{font-family:${bodyFont},-apple-system,BlinkMacSystemFont,sans-serif;font-size:${fontSize}px;line-height:${lineHeight};margin:0;padding:40px 32px 80px;overflow-wrap:break-word}main{max-width:${width}px;margin:auto}h1,h2,h3,h4,h5,h6{font-weight:650;line-height:1.25;letter-spacing:-.015em;margin:1.8em 0 .65em;scroll-margin-top:24px}h1{font-size:2.2em;margin-top:.25em}h2{font-size:1.6em}h3{font-size:1.3em}h4{font-size:1.1em}p,ul,ol,blockquote,pre,table,figure,details{margin:1em 0}a{color:var(--link);text-decoration-thickness:1px;text-underline-offset:3px}img,video{max-width:100%;height:auto}hr{border:0;border-top:1px solid var(--border);margin:2em 0}blockquote{color:var(--muted);border-left:3px solid var(--border);padding:0 1.2em;margin-left:0;margin-right:0}pre,code,kbd,samp{font-family:${codeFont},Menlo,monospace}code{font-size:.87em;background:var(--fill);padding:.16em .32em;border-radius:4px}pre{overflow:auto;background:var(--fill);padding:16px 18px;border-radius:7px;line-height:1.5}pre code{padding:0;background:none;font-size:.84em;border-radius:0;white-space:pre}table{border-collapse:collapse;display:block;max-width:100%;overflow:auto}th,td{border:1px solid var(--border);padding:7px 12px;text-align:left}th{background:var(--fill);font-weight:600}tr:nth-child(even){background:var(--fill)}li>p{margin:.4em 0}input[type=checkbox]{accent-color:var(--link);margin:0 .4em 0 0}mark{background:${colors.mark};color:inherit;padding:.05em .15em;border-radius:2px}.footnotes{font-size:.85em;color:var(--muted);border-top:1px solid var(--border);margin-top:3em}.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}.leaf-callout{padding:12px 16px;background:var(--fill);border-left:3px solid var(--link);border-radius:0 5px 5px 0;margin:1em 0}.leaf-callout-title{font-weight:600;margin:0 0 .4em}.leaf-callout p:last-child{margin-bottom:0}.leaf-callout-warning,.leaf-callout-caution{border-color:#b68a32}.leaf-callout-danger,.leaf-callout-failure{border-color:#b35f5f}.leaf-component{padding:12px 16px;background:var(--fill);margin:1em 0;border-radius:6px}.leaf-component-label{font-size:.8em;font-weight:600;color:var(--muted);display:block;margin-bottom:.4em}.leaf-inert-source{font-size:.85em}.leaf-frontmatter{font-size:.85em;color:var(--muted)}summary{cursor:pointer;font-weight:500}.leaf-diagram{overflow:auto;text-align:center;padding:12px 0}.leaf-diagram svg{max-width:100%;height:auto;vertical-align:middle}.leaf-diagram-error{border-left:3px solid #b35f5f;padding-left:14px}.leaf-diagram-error figcaption,.leaf-render-error{color:${dark ? '#e79c9c' : '#a83d3d'};font-size:.85em}.leaf-math{overflow:auto;text-align:center;padding:4px 0}.leaf-toc{font-size:.9em;color:var(--muted);margin:1.5em 0 2em}.leaf-toc p{font-weight:600}.leaf-toc ol{list-style:none;padding:0}.leaf-toc li{margin:.3em 0}.toc-level-2{padding-left:1em}.toc-level-3{padding-left:2em}.toc-level-4,.toc-level-5,.toc-level-6{padding-left:3em}.leaf-wiki-link{text-decoration-style:dotted}.leaf-embed-link::before{content:'↗ ';color:var(--muted)}
.hljs-comment,.hljs-quote{color:${dark ? '#9caa99' : '#6c7b69'}}.hljs-keyword,.hljs-selector-tag,.hljs-type{color:${dark ? '#cf9ce2' : '#865095'}}.hljs-string,.hljs-regexp{color:${dark ? '#a4c89a' : '#5c7d45'}}.hljs-number,.hljs-literal,.hljs-symbol{color:${dark ? '#d9ad83' : '#9c6540'}}.hljs-title,.hljs-function,.hljs-section{color:${dark ? '#9abadd' : '#416e9a'}}.hljs-built_in,.hljs-attr{color:${dark ? '#d8c889' : '#87773e'}}
@media(max-width:600px){body{padding:24px 18px 60px}}@media print{html,body{background:white;color:#222}body{padding:0;font-size:11pt}main{max-width:none}a{color:inherit}pre,blockquote,figure{break-inside:avoid}h1,h2,h3,h4{break-after:avoid}.leaf-toc{display:none}.leaf-diagram svg{max-height:650px}}`;
  return { html: `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data: file: leaf:; font-src data:; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'"><title>${escape(options.title || 'Untitled')}</title><style>${css}\n${mathCSS}</style></head><body><main>${toc}${result.html}</main></body></html>` };
}

function guarded(operation) {
  try { return operation(); }
  catch (error) { return { error: { message: String(error?.message ?? error), code: String(error?.code ?? 'rendering'), line: Number(error?.line ?? 0), column: Number(error?.column ?? 0) } }; }
}
export const diagram = (source, theme = 'light') => guarded(() => renderDiagram(String(source), ['dark', 'black'].includes(String(theme).toLowerCase())));
export const fragment = source => guarded(() => ({ html: renderMarkup(String(source)).html }));
export const document = (source, options = {}, mathCSS = '') => guarded(() => documentHTML(String(source), options, mathCSS));
