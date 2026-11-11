// @ts-check
import { defineConfig } from 'astro/config';
import tailwindcss from '@tailwindcss/vite';

// The site is fully static: Astro builds to ./dist, which the Cloudflare Worker
// in wrangler.jsonc serves as static assets at wortel.sh.
//
// Tailwind is here for one reason: the app window on the page is generated
// from the Opmaak canvas (src/app/gen/*.astro), whose markup is Tailwind. The
// site's own styles are plain CSS in src/styles/site.css and per-component
// <style> blocks.
export default defineConfig({
  site: 'https://wortel.sh',
  output: 'static',
  server: { port: 4340 },
  devToolbar: { enabled: false },
  vite: { plugins: [tailwindcss()] },
});
