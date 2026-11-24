// The little Markdown the copy in site.ts may carry inside a sentence, and the
// two ways it is read.
//
//   `claude`        something you type, a path or a file name    <code>
//   `⌘N`            a key or a chord, written the same way       <kbd>
//   **the claim**   the few words a paragraph is about           <strong>
//
// The Markdown the site also publishes (data/markdown.ts) passes the strings
// through as they are, so one string serves both. Anything that is plain text
// (the structured data, a meta description) goes through plain().

const KEYS = /^(?:[⌘⌥⇧⌃]+(?:Tab|[^\s⌘⌥⇧⌃]))$/u;
const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/** One string as HTML, for set:html. */
export const inline = (s: string): string =>
  esc(s)
    .replace(/`([^`]+)`/g, (_, c: string) => (KEYS.test(c) ? `<kbd>${c}</kbd>` : `<code>${c}</code>`))
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');

/** The same string with the marks taken off. */
export const plain = (s: string): string => s.replace(/`([^`]+)`/g, '$1').replace(/\*\*([^*]+)\*\*/g, '$1');
