// /layouts.md: this page as Markdown, for agents. Linked from the page's <head>
// as rel="alternate" type="text/markdown". Rendered by data/markdown.ts.
import type { APIRoute } from 'astro';
import { featureMd, markdownResponse } from '../data/markdown';
import { LAYOUTS_PAGE } from '../data/site';

export const GET: APIRoute = () => markdownResponse(featureMd(LAYOUTS_PAGE));
