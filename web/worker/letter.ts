// ==========================================================================
// The letter: the decisions, with nothing that needs a Worker to run.
//
// The letter is an email when something big ships, a few times a year. This
// file is everything about it that can be tested under `node --test`: what
// counts as an address, what a form post says, what the confirmation mail
// reads, how long things last. letter-routes.ts is the part that touches D1,
// the mail binding and the requests (letter-routes.test.ts runs it on SQLite).
//
// What is kept about a person is their address, the day they joined, which
// form they used and a random token, and nothing else: no IP, no user agent,
// no country. The privacy page (src/content/legal/privacy.md, "The letter")
// says exactly that, and changes in the same commit as anything here that
// would make it untrue.
// ==========================================================================

/** Where a signup came from. Kept so a dead form can be told from a quiet one. */
export const SOURCES = ['download', 'updates', 'letter'] as const;
export type Source = (typeof SOURCES)[number];

/** An unconfirmed address is forgotten after this long. */
export const PENDING_TTL = 7 * 24 * 60 * 60;
/**
 * At most one confirmation mail per address in this long, however often the
 * form is sent. Enforced by the one statement in letter-routes.ts that claims
 * the mail, so it holds for posts that arrive together.
 */
export const MAIL_COOLDOWN = 24 * 60 * 60;

/**
 * The address as it is stored and compared: trimmed and lowercased. Null when
 * it is not one worth sending a mail to. This is deliberately loose: the
 * confirmation mail is the real test, and a strict pattern only ever turns
 * away someone with an unusual but working address.
 */
export function normaliseEmail(input: unknown): string | null {
  if (typeof input !== 'string') return null;
  const email = input.trim().toLowerCase();
  // RFC 5321 caps a path at 254.
  if (email.length < 3 || email.length > 254) return null;
  if (/[\s<>()\[\]\\,;:"]/.test(email)) return null;
  const at = email.lastIndexOf('@');
  if (at < 1 || at !== email.indexOf('@')) return null;
  const local = email.slice(0, at);
  const domain = email.slice(at + 1);
  if (local.length > 64) return null;
  // A domain with a dot, no empty labels, and a top level of two letters or more.
  const labels = domain.split('.');
  if (labels.length < 2 || labels.some((l) => !/^[a-z0-9-]+$/.test(l) || l.startsWith('-') || l.endsWith('-'))) return null;
  if (!/^[a-z]{2,}$|^xn--[a-z0-9-]+$/.test(labels[labels.length - 1])) return null;
  return email;
}

export type Join =
  | { kind: 'join'; email: string; source: Source }
  /** The hidden field was filled in: a bot. Answered as if it worked, and nothing is done. */
  | { kind: 'bot' }
  | { kind: 'invalid' };

/** What a signup form post asks for. */
export function parseJoin(form: { get(name: string): unknown }): Join {
  // `website` is hidden from people (off screen, aria-hidden, no tab stop) and
  // left empty by them. A form filler fills in everything.
  const trap = form.get('website');
  if (typeof trap === 'string' && trap.trim() !== '') return { kind: 'bot' };
  const email = normaliseEmail(form.get('email'));
  if (!email) return { kind: 'invalid' };
  const raw = form.get('source');
  const source = SOURCES.find((s) => s === raw) ?? 'letter';
  return { kind: 'join', email, source };
}

/** A token is 32 random bytes as base64url: 43 characters. */
export function encodeToken(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function newToken(): string {
  return encodeToken(crypto.getRandomValues(new Uint8Array(32)));
}

/** Whether a string could be a token at all, so a junk one never reaches the database. */
export function isToken(input: unknown): input is string {
  return typeof input === 'string' && /^[A-Za-z0-9_-]{43}$/.test(input);
}

export interface Mail {
  subject: string;
  text: string;
  html: string;
}

/**
 * The one mail this code sends: the link that makes a signup real. Plain
 * words, no images, no tracking, and every link goes straight to wortel.sh.
 * The links open a page with a button rather than doing the thing, because
 * mail scanners open every link in a message, and a link that confirmed on
 * opening would confirm every address anyone typed in.
 */
export function confirmationMail(origin: string, token: string): Mail {
  const confirm = `${origin}/letter/confirm?t=${token}`;
  const subject = 'Confirm the Wortel letter';
  const text = [
    'Someone, hopefully you, asked for the Wortel letter at this address: an email when something big ships, a few times a year.',
    '',
    'To confirm, open this link and press Confirm:',
    confirm,
    '',
    'Didn’t ask for this? Ignore this email and nothing happens. The address is forgotten in seven days.',
    '',
    'Wortel',
    origin,
  ].join('\n');
  const html = `<!doctype html>
<html lang="en">
<body style="margin:0;padding:32px 24px;background:#fbfaf7;color:#1b1b17;font:16px/24px -apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif;">
<div style="max-width:480px;">
<p style="margin:0 0 16px;">Someone, hopefully you, asked for the Wortel letter at this address: an email when something big ships, a few times a year.</p>
<p style="margin:0 0 24px;"><a href="${confirm}" style="display:inline-block;padding:8px 24px;border-radius:999px;background:#1b1b17;color:#fbfaf7;text-decoration:none;font-weight:500;">Confirm</a></p>
<p style="margin:0 0 16px;color:#6b6960;">Didn’t ask for this? Ignore this email and nothing happens. The address is forgotten in seven days.</p>
<p style="margin:0;color:#6b6960;">Wortel<br><a href="${origin}" style="color:#6b6960;">${origin.replace(/^https?:\/\//, '')}</a></p>
</div>
</body>
</html>`;
  return { subject, text, html };
}
