// Opmaak JSX dump -> compact HTML fragment for an .astro component.
// Usage: node jsx2astro.mjs <in.jsx> <out.astro> [--select "Name"] [--assets ids.txt]
// Follows JSX whitespace rules exactly so whitespace-pre terminal rows survive.
import { parse } from '@babel/parser';
import fs from 'fs';

const [inFile, outFile, ...rest] = process.argv.slice(2);
const opt = {};
for (let i = 0; i < rest.length; i += 2) opt[rest[i].replace(/^--/, '')] = rest[i + 1];

const src = fs.readFileSync(inFile, 'utf8');
const ast = parse(`<>${src}</>`, { plugins: ['jsx'] });
const top = ast.program.body[0].expression;

const ids = new Set();
const assetUrl = (id) => { ids.add(id); return `/app/${id}.png`; };
const rewrite = (s) => s.replace(/\/a\/([0-9a-f]{32})/g, (_, id) => assetUrl(id));

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/\{/g, '&#123;').replace(/\}/g, '&#125;');
const escAttr = (s) => s.replace(/&/g, '&amp;').replace(/"/g, '&quot;')
  .replace(/\{/g, '&#123;').replace(/\}/g, '&#125;');

// React's cleanJSXElementLiteralChild
function cleanText(raw) {
  const lines = raw.split(/\r\n|\n|\r/);
  let lastNonEmpty = 0;
  for (let i = 0; i < lines.length; i++) if (/[^ \t]/.test(lines[i])) lastNonEmpty = i;
  let str = '';
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const isFirst = i === 0, isLast = i === lines.length - 1, isLastNonEmpty = i === lastNonEmpty;
    let t = line.replace(/\t/g, ' ');
    if (!isFirst) t = t.replace(/^[ ]+/, '');
    if (!isLast) t = t.replace(/[ ]+$/, '');
    if (t) { if (!isLastNonEmpty) t += ' '; str += t; }
  }
  return str;
}

const nameOf = (el) => {
  const a = el.openingElement.attributes.find((a) => a.name?.name === 'name');
  return a?.value?.value;
};
function attrValue(a) {
  if (!a.value) return true;
  if (a.value.type === 'StringLiteral') return a.value.value;
  const e = a.value.expression;
  if (e.type === 'StringLiteral') return e.value;
  if (e.type === 'NumericLiteral') return String(e.value);
  if (e.type === 'TemplateLiteral') return e.quasis.map((q) => q.value.cooked).join('');
  throw new Error('attr expr ' + e.type);
}

const SKIP_ROOT_ATTRS = new Set(['x', 'y', 'mode']);
function emit(node, depth = 0) {
  if (node.type === 'JSXText') return esc(cleanText(node.value));
  if (node.type === 'JSXExpressionContainer') {
    const e = node.expression;
    if (e.type === 'JSXEmptyExpression') return '';
    if (e.type === 'StringLiteral') return esc(e.value);
    if (e.type === 'TemplateLiteral') return esc(e.quasis.map((q) => q.value.cooked).join(''));
    throw new Error('child expr ' + e.type);
  }
  if (node.type === 'JSXFragment') return node.children.map((c) => emit(c, depth)).join('');
  const tagName = node.openingElement.name.name;
  const tag = tagName === 'Image' ? 'img' : tagName;
  if (/^[A-Z]/.test(tag)) throw new Error('component ' + tag);
  let attrs = '';
  for (const a of node.openingElement.attributes) {
    const k = a.name.name; let v = attrValue(a);
    if (SKIP_ROOT_ATTRS.has(k)) continue;
    if (k === 'width' || k === 'height') { if (tag !== 'img') continue; }
    if (k === 'className') { attrs += ` class="${escAttr(rewrite(v))}"`; continue; }
    if (k === 'name') { attrs += ` data-name="${escAttr(v)}"`; continue; }
    if (k === 'src') { attrs += ` src="${escAttr(rewrite(v))}"`; continue; }
    if (v === true) { attrs += ` ${k}`; continue; }
    attrs += ` ${k}="${escAttr(String(v))}"`;
  }
  if (tag === 'img') { attrs += ' decoding="async" draggable="false"'; return `<img${attrs}>`; }
  const kids = node.children.map((c) => emit(c, depth + 1)).join('');
  return `<${tag}${attrs}>${kids}</${tag}>`;
}

function find(node, name) {
  if (node.type === 'JSXElement') {
    if (nameOf(node) === name) return node;
  }
  for (const c of node.children || []) {
    if (c.type === 'JSXElement' || c.type === 'JSXFragment') { const r = find(c, name); if (r) return r; }
  }
  return null;
}

let target = top;
if (opt.select) {
  const parts = opt.select.split('/');
  for (const p of parts) { target = find(target, p); if (!target) throw new Error('not found ' + p); }
}
let html = emit(target);
if (opt.addclass) html = html.replace(/^<(\w+)([^>]*?) class="/, `<$1$2 class="${opt.addclass} `);
const header = `---\n// Generated from the Opmaak canvas 2v3opz6osv (${opt.select || 'root'}) by jsx2astro.mjs.\n// Edit the canvas and regenerate rather than hand-editing this file.\n---\n`;
fs.writeFileSync(outFile, header + html + '\n');
if (opt.assets) fs.appendFileSync(opt.assets, [...ids].join('\n') + '\n');
console.log(outFile, html.length, 'bytes', ids.size, 'assets');
