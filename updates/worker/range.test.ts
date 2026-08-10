// Content-Range, pinned by value.
//
// Every case here was a live 206 that carried the correct bytes under a header
// that was wrong, which is the reason this file exists at all: the archive
// arrives intact, the checksum matches, and only a client strict enough to
// parse the header notices. Nothing about the payload can lead you back to it.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { contentRange } from './index.ts';

const SIZE = 18421843; // a real Wortel-latest.zip

test('an ordinary head-of-file range', () => {
  // R2 declares every field on the range object, so `suffix` is PRESENT and
  // undefined here. Checking with `in` sent this down the suffix branch and
  // produced "bytes NaN-18421842/18421843" against the live bucket.
  assert.equal(
    contentRange({ offset: 0, length: 100, suffix: undefined } as R2Range, SIZE),
    'bytes 0-99/18421843',
  );
});

test('a mid-file range, which is what a resumed download asks for', () => {
  assert.equal(
    contentRange({ offset: 1000, length: 500, suffix: undefined } as R2Range, SIZE),
    'bytes 1000-1499/18421843',
  );
});

test('an open-ended range runs to the last byte', () => {
  // "bytes=1000-" : offset with no length. Sparkle resuming after a drop.
  assert.equal(
    contentRange({ offset: 1000 } as R2Range, SIZE),
    `bytes 1000-${SIZE - 1}/${SIZE}`,
  );
});

test('a real suffix range is measured from the end', () => {
  // "bytes=-500" : the last 500 bytes.
  assert.equal(
    contentRange({ suffix: 500 } as R2Range, SIZE),
    `bytes ${SIZE - 500}-${SIZE - 1}/${SIZE}`,
  );
});

test('no NaN survives any shape', () => {
  const shapes: R2Range[] = [
    { offset: 0, length: 100, suffix: undefined } as R2Range,
    { offset: 0 } as R2Range,
    { length: 10 } as R2Range,
    { suffix: 1 } as R2Range,
    {} as R2Range,
  ];
  for (const shape of shapes) {
    assert.doesNotMatch(
      contentRange(shape, SIZE),
      /NaN|undefined/,
      `produced a broken header for ${JSON.stringify(shape)}`,
    );
  }
});
