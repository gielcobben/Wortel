// Reveal on enter: anything marked data-reveal fades up the first time it
// comes on screen, once. data-reveal-group staggers its children.
const io = new IntersectionObserver(
  (entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      e.target.classList.add('in');
      io.unobserve(e.target);
    }
  },
  { rootMargin: '0px 0px -10% 0px', threshold: 0.01 },
);
document.querySelectorAll<HTMLElement>('[data-reveal-group]').forEach((g) => {
  const step = Number(g.dataset.revealGroup) || 0.08;
  g.querySelectorAll<HTMLElement>('[data-reveal]').forEach((el, i) => el.style.setProperty('--d', `${i * step}s`));
});
document.querySelectorAll('[data-reveal]:not([data-reveal="manual"])').forEach((el) => io.observe(el));

// Photos and the app's own pictures below the first screen are not fetched
// with the page. Anything marked data-photo asks for them when it comes
// within a screen and a half, which is before anyone can see it arrive.
const near = new IntersectionObserver(
  (entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      (e.target as HTMLElement).dataset.near = '';
      e.target.querySelectorAll<HTMLImageElement>('img[loading="lazy"]').forEach((img) => { img.loading = 'eager'; });
      near.unobserve(e.target);
    }
  },
  { rootMargin: '1500px 0px' },
);
document.querySelectorAll('[data-photo]').forEach((el) => near.observe(el));

// Mobile Safari only shows a pressed link as :active when the page listens
// for touches at all. The pressed states are in site.css (Touch).
document.addEventListener('touchstart', () => {}, { passive: true });
