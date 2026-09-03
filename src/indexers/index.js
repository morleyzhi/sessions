const fs = require('fs');
const path = require('path');
const claude = require('./claude');
const codex = require('./codex');
const cursor = require('./cursor');

const INDEXERS = { claude, codex, cursor };

const statTarget = (target) => {
  const stats = fs.statSync(target);
  if (stats.isDirectory()) {
    const db = fs.statSync(path.join(target, 'store.db'));
    return { mtimeMs: db.mtimeMs, size: db.size };
  }
  return { mtimeMs: stats.mtimeMs, size: stats.size };
};

const toSummary = (session, fingerprint) => ({
  id: session.id,
  tool: session.tool,
  title: session.title,
  cwd: session.cwd,
  project: session.cwd ? path.basename(session.cwd) : '',
  filePath: session.filePath,
  startedAt: session.startedAt,
  updatedAt: session.updatedAt,
  messageCount: session.messageCount,
  preview: session.preview,
  searchText: session.searchText,
  resumeCommand: INDEXERS[session.tool].resumeCommand(session),
  fingerprint,
});

const buildIndex = async ({ cachePath, onProgress = () => {} }) => {
  let cache = {};
  try {
    cache = JSON.parse(fs.readFileSync(cachePath, 'utf8'));
  } catch {
    cache = {};
  }

  const codexTitles = codex.readTitles();
  const targets = [];
  for (const [tool, indexer] of Object.entries(INDEXERS)) {
    for (const target of indexer.listFiles()) targets.push({ tool, target });
  }

  const summaries = [];
  const nextCache = {};
  let done = 0;

  for (const { tool, target } of targets) {
    done++;
    let fingerprint;
    try {
      const { mtimeMs, size } = statTarget(target);
      fingerprint = `v3:${mtimeMs}:${size}`;
    } catch {
      continue;
    }

    const cached = cache[target];
    if (cached && cached.fingerprint === fingerprint) {
      if (!cached.resumeCommand) cached.resumeCommand = INDEXERS[tool].resumeCommand(cached);
      nextCache[target] = cached;
      summaries.push(cached);
      continue;
    }

    try {
      const session = tool === 'codex'
        ? await codex.parseFile(target, codexTitles)
        : await INDEXERS[tool].parseFile(target);
      if (!session.messageCount) continue;
      const summary = toSummary(session, fingerprint);
      nextCache[target] = summary;
      summaries.push(summary);
    } catch {
      continue;
    }
    if (done % 10 === 0) onProgress({ done, total: targets.length });
  }

  onProgress({ done: targets.length, total: targets.length });
  try {
    fs.mkdirSync(path.dirname(cachePath), { recursive: true });
    fs.writeFileSync(cachePath, JSON.stringify(nextCache));
  } catch {
    /* cache is an optimization; a failed write is not fatal */
  }

  summaries.sort((a, b) => b.updatedAt - a.updatedAt);
  const unique = new Map();
  for (const summary of summaries) {
    const key = `${summary.tool}:${summary.id}`;
    const existing = unique.get(key);
    if (!existing || summary.messageCount > existing.messageCount) unique.set(key, summary);
  }
  return [...unique.values()].sort((a, b) => b.updatedAt - a.updatedAt);
};

const loadSession = async ({ tool, filePath }) => {
  const indexer = INDEXERS[tool];
  if (!indexer) return null;
  const session = tool === 'codex'
    ? await codex.parseFile(filePath, codex.readTitles())
    : await indexer.parseFile(filePath);
  return { ...session, resumeCommand: indexer.resumeCommand(session) };
};

const resumeCommandFor = (summary) => INDEXERS[summary.tool].resumeCommand(summary);

module.exports = { buildIndex, loadSession, resumeCommandFor };
