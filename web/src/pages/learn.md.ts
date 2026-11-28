// /learn.md: this page as Markdown, for agents. Linked from the page's <head>
// as rel="alternate" type="text/markdown". Rendered by data/markdown.ts.
import type { APIRoute } from 'astro';
import { learnMd, markdownResponse } from '../data/markdown';

export const GET: APIRoute = () => markdownResponse(learnMd());
