const fs = require('fs');
const path = require('path');
const os = require('os');
const readline = require('readline');
const { extractContent, buildSearchText, firstPrompt, lastMessageTime, collapse } = require('./text');

const ROOT = path.join(os.homedir(), '.codex', 'sessions');
const INDEX_FILE = path.join(os.homedir(), '.codex', 'session_index.jsonl');

const walk = (dir, files = []) => {
  if (!fs.existsSync(dir)) return files;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, files);
    else if (entry.name.endsWith('.jsonl')) files.push(full);
  }
  return files;
};

const listFiles = () => walk(ROOT);

const readTitles = () => {
  const titles = new Map();
  if (!fs.existsSync(INDEX_FILE)) return titles;
  for (const line of fs.readFileSync(INDEX_FILE, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try {
      const entry = JSON.parse(line);
      if (entry.id && entry.thread_name) titles.set(entry.id, entry.thread_name);
    } catch {
      continue;
    }
  }
  return titles;
};

const isInjectedContext = (text) =>
  text.startsWith('# AGENTS.md instructions') ||
  text.startsWith('<user_instructions>') ||
  text.startsWith('<environment_context>') ||
  text.startsWith('<skills_instructions>');

const parseFile = async (filePath, titles = new Map()) => {
  const stream = readline.createInterface({ input: fs.createReadStream(filePath), crlfDelay: Infinity });
  const messages = [];
  let id = '';
  let cwd = '';
  let startedAt = null;
  let updatedAt = null;

  for await (const line of stream) {
    if (!line.trim()) continue;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }
    if (event.timestamp) {
      const time = Date.parse(event.timestamp);
      if (!Number.isNaN(time)) {
        if (startedAt === null || time < startedAt) startedAt = time;
        if (updatedAt === null || time > updatedAt) updatedAt = time;
      }
    }
    if (event.type === 'session_meta') {
      id = event.payload?.session_id || event.payload?.id || '';
      cwd = event.payload?.cwd || '';
      continue;
    }
    if (event.type !== 'response_item') continue;
    const payload = event.payload || {};
    if (payload.type === 'function_call') {
      messages.push({ role: 'assistant', text: `[tool: ${payload.name || 'unknown'}]`, timestamp: null });
      continue;
    }
    if (payload.type !== 'message') continue;
    if (payload.role !== 'user' && payload.role !== 'assistant') continue;
    const text = extractContent(payload.content).trim();
    if (!text || isInjectedContext(text)) continue;
    messages.push({ role: payload.role, text, timestamp: event.timestamp ? Date.parse(event.timestamp) : null });
  }

  const stats = fs.statSync(filePath);
  if (!id) id = path.basename(filePath, '.jsonl').replace(/^rollout-\d{4}-\d{2}-\d{2}T[\d-]+-/, '');
  return {
    id,
    tool: 'codex',
    title: titles.get(id) || firstPrompt(messages) || 'Untitled session',
    cwd,
    filePath,
    startedAt: startedAt ?? stats.birthtimeMs,
    updatedAt: lastMessageTime(messages) ?? updatedAt ?? stats.mtimeMs,
    messageCount: messages.length,
    preview: collapse(firstPrompt(messages)),
    searchText: buildSearchText(messages),
    messages,
  };
};

const resumeCommand = (session) => {
  const target = session.cwd ? `cd ${JSON.stringify(session.cwd)} && ` : '';
  return `${target}codex resume ${session.id}`;
};

module.exports = { tool: 'codex', listFiles, parseFile, resumeCommand, readTitles };
