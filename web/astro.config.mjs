// @ts-check
import { defineConfig } from 'astro/config';

// The landing page is fully static — Astro builds to ./dist, which the
// Cloudflare Worker in wrangler.jsonc serves as static assets at wortel.sh.
export default defineConfig({
  site: 'https://wortel.sh',
  output: 'static',
});
