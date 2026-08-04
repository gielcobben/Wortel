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

// ---- terminal reflow -------------------------------------------------------
// Wrap a parsed inline run to `cols` characters, the way a terminal re-wraps
// its output when you drag the window. Hard-coded line breaks are only ever
// right at the one width they were authored for, and this window is a different
// width in every section of the tour.
//
// Wrapping happens over SEGMENTS, not over the raw string, so a break can land
// inside a **bold** run or a [link](#) without splitting the markup: each
// output line is its own array of segments carrying the original styles.
export function wrapSegments(segs, cols) {
  if (cols < 2) return [segs];
  const lines = [];
  let cur = [];
  let len = 0;

  const flush = () => { lines.push(cur); cur = []; len = 0; };
  const put = (seg, t) => {
    // Merge into the previous span when the style matches, so a wrapped
    // sentence is a handful of DOM nodes rather than one per word.
    const prev = cur[cur.length - 1];
    if (prev && prev.bold === seg.bold && prev.italic === seg.italic && prev.link === seg.link) {
      prev.t += t;
    } else {
      cur.push({ ...seg, t });
    }
    len += t.length;
  };

  for (const seg of segs) {
    for (const piece of seg.t.split(/(\s+)/)) {
      if (piece === '') continue;
      if (/^\s+$/.test(piece)) {
        // A run of spaces never starts a line and never pushes one over.
        if (len === 0) continue;
        if (len + piece.length > cols) flush();
        else put(seg, piece);
        continue;
      }
      if (len + piece.length > cols && len > 0) flush();
      let word = piece;
      // A single word longer than the line gets broken, like a terminal does.
      while (word.length > cols) {
        put(seg, word.slice(0, cols - len));
        word = word.slice(cols - len);
        flush();
      }
      put(seg, word);
    }
  }
  if (cur.length) lines.push(cur);
  return lines.length ? lines : [[]];
}
