// Small tools for acting on the generated app windows (src/app/gen). The
// markup comes from the Opmaak canvas and keeps each layer's name as
// data-name, so a scene can find "the Landing page hero row" or "the Terminal"
// and do to it what the real app would: select it, give it a status, print a
// line. Everything here clones the canvas's own nodes, so nothing a scene adds
// is styled by hand.
import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';

gsap.registerPlugin(ScrollTrigger);

export const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;

export const named = (root: ParentNode, name: string) =>
  root.querySelector<HTMLElement>(`[data-name="${name}"]`);

/** Build a looping timeline when el comes on screen; pause it when it leaves. */
export function whileVisible(el: Element, make: () => gsap.core.Timeline) {
  let tl: gsap.core.Timeline | null = null;
  ScrollTrigger.create({
    trigger: el,
    start: 'top 75%',
    end: 'bottom 25%',
    onToggle: (self) => {
      if (self.isActive) { tl ??= make(); tl.play(); } else tl?.pause();
    },
  });
}

// ---- the sidebar ----------------------------------------------------------

export type Status = 'working' | 'attention' | 'done' | 'none';

export class Sidebar {
  root: HTMLElement;
  private pill: HTMLElement;
  private working: HTMLElement;
  private attention: HTMLElement;
  selected: string;

  constructor(root: HTMLElement) {
    this.root = root;
    this.pill = named(root, 'Pill')!;
    this.selected = this.pill.parentElement!.dataset.name!;
    // The canvas has one of each status; they are the moulds for the rest.
    this.working = named(root, 'Working')!.parentElement!;
    this.attention = named(root, 'Attention')!.parentElement!;
  }

  row(name: string) { return named(this.root, name)!; }

  /** Move the selection to a row, the way a click does. */
  select(name: string, animate = true) {
    const to = this.row(name);
    if (!to || name === this.selected) return;
    const from = this.pill.getBoundingClientRect();
    to.prepend(this.pill);
    this.selected = name;
    if (!animate) return;
    const now = this.pill.getBoundingClientRect();
    gsap.fromTo(this.pill, { y: from.top - now.top, height: from.height }, { y: 0, height: now.height, duration: 0.32, ease: 'power3.out', clearProps: 'transform,height' });
  }

  /** Give a row a status the way the app marks one. */
  status(name: string, status: Status) {
    const row = this.row(name);
    row.querySelector('[data-name="Status"]')?.remove();
    row.classList.remove('pr-3'); row.classList.add('pr-[34px]');
    if (status === 'none') return;
    const mould = status === 'working' ? this.working : this.attention;
    const el = mould.cloneNode(true) as HTMLElement;
    if (status !== 'working') {
      const dot = el.firstElementChild as HTMLElement;
      dot.classList.remove('bg-chart-1', 'bg-chart-2');
      dot.classList.add(status === 'attention' ? 'bg-chart-1' : 'bg-chart-2');
      gsap.fromTo(dot, { scale: 0 }, { scale: 1, duration: 0.4, ease: 'back.out(3)' });
    }
    row.appendChild(el);
    this.pulse();
  }

  private pulseTween?: gsap.core.Tween;
  /** Working dots breathe, in turn. Re-run after statuses change. */
  pulse() {
    this.pulseTween?.kill();
    const dots = this.root.querySelectorAll('[data-name="Working"] > div');
    gsap.set(dots, { opacity: 1 });
    if (dots.length && !reduced()) {
      this.pulseTween = gsap.to(dots, { opacity: 0.2, duration: 0.5, ease: 'sine.inOut', stagger: { each: 0.18, repeat: -1, yoyo: true } });
    }
  }
}

// ---- the terminal ---------------------------------------------------------

type Kind = 'You' | 'Claude' | 'Tool' | 'Result' | 'Worked';

export class Terminal {
  root: HTMLElement;
  private moulds = new Map<string, HTMLElement>();
  private anchor: Element;
  prompt: HTMLElement;

  constructor(root: HTMLElement) {
    this.root = root;
    for (const k of ['You', 'Claude', 'Tool', 'Result', 'Worked']) {
      const m = named(root, k);
      if (m) this.moulds.set(k, m.cloneNode(true) as HTMLElement);
    }
    // Lines are printed above the rule that opens the prompt box.
    this.anchor = named(root, 'Rule')!;
    this.prompt = named(root, 'Prompt')!;
  }

  /** The agent's lines, in order: everything above the prompt box. */
  lines() {
    const all = Array.from(this.root.children) as HTMLElement[];
    return all.slice(0, all.indexOf(this.anchor as HTMLElement));
  }

  clear() { this.lines().forEach((l) => l.remove()); }

  /** Replace what is on screen with another session's lines. */
  swap(nodes: HTMLElement[]) {
    this.clear();
    nodes.forEach((n) => this.root.insertBefore(n, this.anchor));
  }

  /** Build a screen without showing it: run `fn`, take what it printed. */
  compose(fn: () => void) {
    const keep = this.lines();
    this.clear();
    fn();
    const made = this.lines();
    this.swap(keep);
    return made;
  }

  /** A line with no glyph, the way a prompt's choices are printed. */
  plain(text: string, chosen = false) {
    const p = this.print('Claude', text);
    p.firstElementChild!.remove();
    if (chosen) p.style.color = 'var(--primary)';
    return p;
  }

  /** Print a line. `tool` is the bold verb of a tool line: Read, Bash, Update. */
  print(kind: Kind, text: string, tool?: string) {
    const p = this.moulds.get(kind)!.cloneNode(true) as HTMLElement;
    // Keep the glyph (the first span), replace what follows it.
    const glyph = p.firstElementChild!;
    while (glyph.nextSibling) glyph.nextSibling.remove();
    if (kind === 'Tool' && tool) {
      const verb = (this.moulds.get('Tool')!.children[1] as HTMLElement).cloneNode(false) as HTMLElement;
      verb.textContent = tool;
      p.append(verb, text);
    } else if (kind === 'Result' || kind === 'Worked') {
      const span = (this.moulds.get(kind)!.children[1] as HTMLElement).cloneNode(false) as HTMLElement;
      span.textContent = text;
      p.append(span);
    } else {
      p.append(text);
    }
    this.root.insertBefore(p, this.anchor);
    return p;
  }

  /** An empty row between blocks, as the agent leaves one. */
  gap() {
    const d = document.createElement('div');
    d.className = 'h-[19px] shrink-0';
    this.root.insertBefore(d, this.anchor);
    return d;
  }

  /** What you are typing into the prompt box. */
  typed(text: string) {
    let span = this.prompt.querySelector<HTMLElement>('[data-typed]');
    if (!span) {
      span = document.createElement('span');
      span.dataset.typed = '';
      span.className = 'pl-[17px] whitespace-pre-wrap [overflow-wrap:anywhere] block pr-1';
      this.prompt.classList.remove('h-[19px]');
      this.prompt.classList.add('min-h-[19px]');
      this.prompt.append(span);
    }
    span.textContent = text;
  }
}

/** Press a cluster of keycaps: it appears, the keys dip, it leaves. */
export function pressKeys(tl: gsap.core.Timeline, keys: HTMLElement, at: number, hold = 0.9) {
  tl.fromTo(keys, { opacity: 0, y: 8, scale: 0.96 }, { opacity: 1, y: 0, scale: 1, duration: 0.25, ease: 'power2.out' }, at);
  tl.to(keys.querySelectorAll('kbd'), { y: 2, duration: 0.08, yoyo: true, repeat: 1 }, at + 0.4);
  tl.to(keys, { opacity: 0, y: -4, duration: 0.25, ease: 'power2.in' }, at + hold);
}
