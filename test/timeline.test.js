const { test } = require('node:test');
const assert = require('node:assert/strict');
const { timelineFor } = require('../src/indexers/timeline');
const start = Date.parse('2026-10-09T10:00:00Z');
const user = (minutes, extra = {}) => ({ role: 'user', text: 'Work on this', timestamp: start + minutes * 60000, ...extra });
const assistant = (minutes, text = 'Done') => ({ role: 'assistant', text, timestamp: start + minutes * 60000 });
const timeline = (messages) => timelineFor({ id: 'one', cwd: '/projects/sessions', messages });

test('A prompt opens its original message after tool results', () => {
  const messages = [user(0), { role: 'user', text: '[tool result]', timestamp: start, toolCalls: [] }, assistant(1), user(2)];
  const { rows } = timeline(messages);
  assert.deepEqual(rows.map((row) => row.messageIndex), [0, 3]);
  assert.equal(rows[0].end, start + 60000);
});

test('Missing timestamps are counted without inventing a time', () => {
  const { rows, untimed } = timeline([user(0, { timestamp: null }), user(1)]);
  assert.equal(untimed, 1);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].timestamp, start + 60000);
});

test('A long silence ends inferred activity at the earlier reply', () => {
  const { rows } = timeline([user(0), assistant(2), assistant(90)]);
  assert.equal(rows[0].end, start + 2 * 60000);
});

test('Earlier prompts on a recorded branch share its PR', () => {
  const { rows } = timeline([user(0, { branch: 'mz-timeline' }), assistant(1), user(2, { branch: 'mz-timeline' }), assistant(3, 'Opened https://github.com/example/sessions/pull/12')]);
  assert.deepEqual(rows.map((row) => row.lane), Array(2).fill('https://github.com/example/sessions/pull/12'));
});

test('Several PR mentions keep the project attribution', () => {
  const { rows } = timeline([user(0), assistant(1, 'Compare https://github.com/example/a/pull/1 and https://github.com/example/a/pull/2')]);
  assert.equal(rows[0].kind, 'Session project');
});

test('Subagent prompts do not appear as messages I sent', () => {
  const { rows } = timeline([user(0), user(1, { isSidechain: true }), assistant(2)]);
  assert.equal(rows.length, 1);
});

test('Codex approval sessions keep their own ID', async () => {
  const fs = require('fs');
  const os = require('os');
  const path = require('path');
  const { parseFile } = require('../src/indexers/codex');
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'sessions-test-'));
  const file = path.join(directory, 'approval.jsonl');
  try {
    fs.writeFileSync(file, [
      { type: 'session_meta', payload: { id: 'approval', session_id: 'parent', source: { subagent: { other: 'guardian' } } } },
      { type: 'response_item', timestamp: new Date(start).toISOString(), payload: { type: 'message', role: 'user', content: 'Review this action' } },
    ].map(JSON.stringify).join('\n'));
    const session = await parseFile(file);
    assert.equal(session.id, 'approval');
    assert.equal(timelineFor(session).rows.length, 0);
  } finally {
    fs.rmSync(directory, { recursive: true });
  }
});
