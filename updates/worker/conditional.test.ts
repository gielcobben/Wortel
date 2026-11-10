// Which status a failed precondition gets, pinned by value.
//
// R2 returns an object with no body for ANY failed precondition, and the
// Worker used to call every one of those a 304. For If-None-Match and
// If-Modified-Since that is right. For If-Match and If-Unmodified-Since it says
// the opposite of the truth: a client resuming a file that was replaced by a
// release was told its partial copy was still current instead of being told
// the precondition failed (412).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { preconditionFailedStatus } from './index.ts';

const DATE = 'Sat, 01 Nov 2026 00:00:00 GMT';

test('only if-none-match is a 304', () => {
  assert.equal(preconditionFailedStatus(new Headers({ 'if-none-match': '"abc"' })), 304);
});

test('only if-modified-since is a 304', () => {
  assert.equal(preconditionFailedStatus(new Headers({ 'if-modified-since': DATE })), 304);
});

test('only if-match is a 412', () => {
  assert.equal(preconditionFailedStatus(new Headers({ 'if-match': '"abc"' })), 412);
});

test('only if-unmodified-since is a 412', () => {
  assert.equal(preconditionFailedStatus(new Headers({ 'if-unmodified-since': DATE })), 412);
});

test('if-match together with if-none-match stays a 304', () => {
  // Either could have failed; the conservative answer is today's.
  assert.equal(
    preconditionFailedStatus(new Headers({ 'if-match': '"abc"', 'if-none-match': '"def"' })),
    304,
  );
});

test('no conditional headers at all stays a 304', () => {
  assert.equal(preconditionFailedStatus(new Headers()), 304);
});
