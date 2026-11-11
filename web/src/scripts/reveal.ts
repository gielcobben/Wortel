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
document.querySelectorAll('[data-reveal]').forEach((el) => io.observe(el));
