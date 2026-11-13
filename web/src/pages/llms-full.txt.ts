// /llms-full.txt: every page as Markdown in one file, for a retrieval agent
// that would otherwise have to strip the interactive app window out of the
// HTML to find the prose. The renderers live in data/markdown.ts, shared with
// the per-page /index.md, /docs.md, /compare.md and /updates.md.
import type { APIRoute } from 'astro';
import { llmsFull, markdownResponse } from '../data/markdown';

export const GET: APIRoute = () => markdownResponse(llmsFull());
