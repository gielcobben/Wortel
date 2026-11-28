// /learn: the steps under a film follow it (components/learn/Steps.astro).
//
// A film knows nothing of its steps. They read what it already shows: which
// of its tabs is selected, whether it is playing (.auto on the film), and
// how long it holds the chapter (--hold). Pressing a step presses that tab,
// so the film behaves exactly as if its own tab had been pressed: it goes
// there and pauses.
export function followFilms() {
  for (const list of document.querySelectorAll<HTMLElement>('[data-steps]')) {
    const film = document.querySelector<HTMLElement>(`[data-film="${list.dataset.steps}"]`);
    if (!film) continue;
    const tabs = Array.from(film.querySelectorAll<HTMLElement>('[data-chapter]'));
    const items = Array.from(list.querySelectorAll<HTMLElement>('[data-step]'));
    let current = -1;
    const sync = () => {
      const now = tabs.findIndex((t) => t.getAttribute('aria-selected') === 'true');
      const playing = film.classList.contains('auto');
      list.style.setProperty('--hold', film.style.getPropertyValue('--hold') || '4s');
      // The film restarts its fill by taking .auto off and putting it back
      // in one go; the steps do the same on every change, so theirs restarts
      // with it.
      list.classList.remove('auto');
      if (now !== current) items.forEach((it, i) => it.toggleAttribute('data-current', i === now));
      current = now;
      if (playing) { void list.offsetWidth; list.classList.add('auto'); }
    };
    const watch = new MutationObserver(sync);
    watch.observe(film, { attributes: true, attributeFilter: ['class', 'style'] });
    tabs.forEach((t) => watch.observe(t, { attributes: true, attributeFilter: ['aria-selected'] }));
    items.forEach((it, i) => it.querySelector('button')?.addEventListener('click', () => tabs[i]?.click()));
    sync();
  }
}
