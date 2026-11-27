-- The letter's list (worker/letter.ts). One row per address that asked for it.
-- Nothing else about a person is kept: no IP, no user agent, no country.
-- privacy.md ("The letter") describes this table; change both together.
CREATE TABLE subscribers (
  email        TEXT PRIMARY KEY,      -- trimmed and lowercased
  token        TEXT NOT NULL UNIQUE,  -- 32 random bytes, base64url: confirms and leaves
  source       TEXT NOT NULL,         -- 'download' | 'updates' | 'letter': which form
  created_at   INTEGER NOT NULL,      -- unix seconds; the last confirmation mail for a pending row
  confirmed_at INTEGER,               -- null until the Confirm button is pressed
  mailed_at    INTEGER NOT NULL       -- the last confirmation mail, for the one-a-day limit
);

-- The sweep of pending rows older than a week.
CREATE INDEX subscribers_pending ON subscribers (created_at) WHERE confirmed_at IS NULL;
