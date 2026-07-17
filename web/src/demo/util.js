// Presentational helpers. Both return arrays of spans so the templates render
// declaratively (no innerHTML). Syntax colors resolve via tokens.css vars.

// ---- syntax highlighting (Primer-style, approximate) ----------------------
export function highlight(text, lang) {
  if (!text) return [{ t: '', c: '' }];
  if (lang === 'xml') return hlXml(text);
  if (lang === 'text') return [{ t: text, c: '' }];
  return hlCode(text);
}

function hlCode(text) {
  const spans = [];
  const re = /(\/\/[^\n]*)|('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")|\b(import|from|export|default|const|let|var|function|return|new|true|false|null)\b/g;
  let last = 0, m;
  while ((m = re.exec(text))) {
    if (m.index > last) spans.push({ t: text.slice(last, m.index), c: '' });
    spans.push({ t: m[0], c: m[1] ? 'com' : m[2] ? 'str' : 'kw' });
    last = re.lastIndex;
  }
  if (last < text.length) spans.push({ t: text.slice(last), c: '' });
  return spans;
}

function hlXml(text) {
  const spans = [];
  const re = /([\w:-]+)(?==)|("[^"]*")/g;
  let last = 0, m;
  while ((m = re.exec(text))) {
    if (m.index > last) spans.push({ t: text.slice(last, m.index), c: '' });
    spans.push({ t: m[0], c: m[1] ? 'attr' : 'str' });
    last = re.lastIndex;
  }
  if (last < text.length) spans.push({ t: text.slice(last), c: '' });
  return spans;
}

// ---- terminal inline markup ------------------------------------------------
// **bold**, *italic*, [text](href) → link-colored span.
export function parseInline(s) {
  const out = [];
  const re = /\*\*([^*]+)\*\*|\*([^*]+)\*|\[([^\]]+)\]\(([^)]*)\)/g;
  let last = 0, m;
  while ((m = re.exec(s))) {
    if (m.index > last) out.push({ t: s.slice(last, m.index) });
    if (m[1] !== undefined) out.push({ t: m[1], bold: true });
    else if (m[2] !== undefined) out.push({ t: m[2], italic: true });
    else out.push({ t: m[3], link: true });
    last = re.lastIndex;
  }
  if (last < s.length) out.push({ t: s.slice(last) });
  return out;
}
