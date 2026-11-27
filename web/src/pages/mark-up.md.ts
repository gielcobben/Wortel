// /mark-up.md: this page as Markdown, for agents. Linked from the page's <head>
// as rel="alternate" type="text/markdown". Rendered by data/markdown.ts.
import type { APIRoute } from 'astro';
import { featureMd, markdownResponse } from '../data/markdown';
import { MARKUP_PAGE } from '../data/site';

export const GET: APIRoute = () => markdownResponse(featureMd(MARKUP_PAGE));
