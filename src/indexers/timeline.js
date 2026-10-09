const path = require('path');

// A PR link identifies the work only when the agent mentions exactly one PR.
const timelineFor = (session) => {
  const rows = [];
  let current = null;
  let untimed = 0;
  const finish = () => {
    if (!current) return;
    const prs = [...current.prs];
    const project = path.basename(current.cwd || '') || 'Unknown project';
    const branch = current.branch;
    current.lane = prs.length === 1 ? prs[0] : `${current.cwd || session.id}:${branch || ''}`;
    current.label = prs.length === 1 ? prs[0].replace('https://github.com/', '').replace('/pull/', ' #')
      : `${project}${branch ? ` · ${branch}` : ''}`;
    current.kind = prs.length === 1 ? 'PR mentioned by agent' : branch ? 'Recorded branch' : 'Session project';
    delete current.prs;
    rows.push(current);
  };
  session.messages.forEach((message, messageIndex) => {
    if (message.isSidechain) return;
    if (message.role === 'user' && !message.toolCalls) {
      finish();
      current = null;
      if (!Number.isFinite(message.timestamp)) { untimed++; return; }
      current = {
        messageIndex, timestamp: message.timestamp, end: message.timestamp,
        text: message.text.replace(/\s+/g, ' ').trim().slice(0, 500),
        cwd: message.cwd || session.cwd, branch: message.branch || '', prs: new Set(),
      };
    } else if (current && message.role === 'assistant') {
      // A silence longer than 30 minutes starts no inferred activity span.
      if (Number.isFinite(message.timestamp) && message.timestamp >= current.end && message.timestamp - current.end <= 30 * 60000) {
        current.end = message.timestamp;
      }
      for (const match of message.text.matchAll(/https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/\d+/g)) current.prs.add(match[0]);
    }
  });
  finish();
  // Earlier prompts on the same recorded branch belong to its single mentioned PR.
  const prsByBranch = new Map();
  for (const row of rows) {
    const key = `${row.cwd}:${row.branch}`;
    if (!prsByBranch.has(key)) prsByBranch.set(key, new Map());
    if (row.kind === 'PR mentioned by agent') prsByBranch.get(key).set(row.lane, row.label);
  }
  for (const row of rows) {
    const prs = prsByBranch.get(`${row.cwd}:${row.branch}`);
    if (row.branch && row.kind !== 'PR mentioned by agent' && prs.size === 1) {
      [row.lane, row.label] = [...prs][0];
      row.kind = 'PR inferred from this session';
    }
  }
  return { rows, untimed };
};

// Follow-up messages stay with the task that starts the session.
const isReviewSession = (session) => {
  const prompt = (session.timeline?.rows?.[0]?.text || session.preview || '').trim();
  const opening = prompt.slice(0, 400).replace(/https?:\/\/\S+/g, '');
  const review = /\b(?:re[ -]?)?review\b/i;
  const change = /\b(?:implement|fix|resolve|address|build|create|add|remove|update|change)\b/i;
  const reviewAt = opening.search(review);
  const changeAt = opening.search(change);
  if (changeAt !== -1 && (reviewAt === -1 || changeAt < reviewAt)) return false;
  if (reviewAt !== -1) return true;
  return review.test(session.title || '');
};

module.exports = { timelineFor, isReviewSession };
