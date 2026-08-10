<script>
  // The window, in whichever look the visitor's macOS wears. Everything that
  // mounts the demo goes through here rather than at a look directly, so the
  // choice is made in exactly one place. See look.svelte.js.
  import WortelApp from './WortelApp.svelte';
  import WortelApp27 from './WortelApp27.svelte';
  import { look, detect } from './look.svelte.js';

  const props = $props();

  // After hydration, never during render: the built HTML carries the macOS 27
  // look, and a visitor we place on 26 gets swapped once, before first scroll.
  $effect(() => detect());
</script>

{#if look() === 26}
  <WortelApp {...props} />
{:else}
  <WortelApp27 {...props} />
{/if}
