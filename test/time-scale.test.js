const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createTimeScale } = require('../src/renderer/time-scale');
const minute = 60000;
const now = 1000 * minute;
const row = (start, end = start) => ({ timestamp: now - start * minute, end: now - end * minute });

test('Lunch gaps collapse to a labeled strip', () => {
  const scale = createTimeScale([row(5), row(90)], now, 10 / minute);
  const gaps = scale.segments.filter((segment) => segment.gap);
  assert.equal(gaps.length, 1);
  assert.equal(gaps[0].bottom - gaps[0].top, 44);
  assert.equal(scale.yAt(now - 90 * minute), 114);
});

test('Work across overlapping sessions stays expanded', () => {
  const scale = createTimeScale([row(90, 30), row(40, 0)], now, 10 / minute);
  assert.equal(scale.segments.filter((segment) => segment.gap).length, 0);
  assert.equal(scale.yAt(now - 60 * minute), 600);
});

test('Short pauses keep the selected zoom', () => {
  const scale = createTimeScale([row(5), row(15)], now, 10 / minute);
  assert.equal(scale.segments.filter((segment) => segment.gap).length, 0);
  assert.equal(scale.yAt(now - 15 * minute), 150);
});

test('Zoom preserves the time inside an overnight skip', () => {
  for (const pixels of [2, 10, 40]) {
    const scale = createTimeScale([row(0), row(900)], now, pixels / minute);
    for (const ago of [0, 1, 450, 899, 900]) {
      const timestamp = now - ago * minute;
      assert.ok(Math.abs(scale.timeAt(scale.yAt(timestamp)) - timestamp) < 1);
    }
  }
});

test('An empty timeline has no time skips', () => {
  const scale = createTimeScale([], now, 10 / minute);
  assert.equal(scale.timeAt(0), now);
  assert.equal(scale.segments.filter((segment) => segment.gap).length, 0);
});
