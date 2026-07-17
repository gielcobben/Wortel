// @ts-check
import { defineConfig } from 'astro/config';
import svelte from '@astrojs/svelte';

// The landing page is fully static — Astro builds to ./dist, which the
// Cloudflare Worker in wrangler.jsonc serves as static assets at wortel.sh.
// Svelte powers the interactive product demo (src/demo/*), embedded as a
// client island on the landing page and the standalone /demo route.
export default defineConfig({
  site: 'https://wortel.sh',
  output: 'static',
  integrations: [svelte()],
});
