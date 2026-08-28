const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');
const { extractContent, buildSearchText, firstPrompt, collapse } = require('./text');
const { collectStrings } = require('./protobuf');

const ROOT = path.join(os.homedir(), '.cursor', 'chats');
const SQLITE = '/usr/bin/sqlite3';
const MAX_BLOB_BYTES = 2_000_000;

const listFiles = () => {
  if (!fs.existsSync(ROOT)) return [];
  const chats = [];
  for (const workspace of fs.readdirSync(ROOT)) {
    const workspaceDir = path.join(ROOT, workspace);
    if (!fs.statSync(workspaceDir).isDirectory()) continue;
    for (const chat of fs.readdirSync(workspaceDir)) {
      const chatDir = path.join(workspaceDir, chat);
      if (fs.existsSync(path.join(chatDir, 'store.db'))) chats.push(chatDir);
    }
  }
  return chats;
};

const readBlobs = (dbPath) => {
  const query = `select hex(data) as hex from blobs where length(data) < ${MAX_BLOB_BYTES} order by rowid;`;
  const result = spawnSync(SQLITE, ['-readonly', '-json', dbPath, query], {
    encoding: 'utf8',
    maxBuffer: 512 * 1024 * 1024,
  });
  if (result.status !== 0 || !result.stdout.trim()) return [];
  try {
    return JSON.parse(result.stdout).map((row) => Buffer.from(row.hex, 'hex'));
  } catch {
    return [];
  }
};

const CONTEXT_PREFIXES = ['<user_info>', '<user_rules>', '<project_layout>', '<rules>', '<environment_details>'];

const LEADING_BLOCK = /^<([a-z_]+)>[\s\S]*?<\/\1>\s*/;

const USER_QUERY = /<user_query>([\s\S]*?)<\/user_query>/g;

const stripLeadingBlocks = (text) => {
  const queries = [...text.matchAll(USER_QUERY)].map((match) => match[1].trim()).filter(Boolean);
  if (queries.length) return queries.join('\n\n');
  let output = text.trim();
  while (LEADING_BLOCK.test(output)) output = output.replace(LEADING_BLOCK, '').trim();
  return output;
};

const isInjectedContext = (text) => CONTEXT_PREFIXES.some((prefix) => text.startsWith(prefix));

const readMessages = (dbPath) => {
  const messages = [];
  const seen = new Set();
  for (const buffer of readBlobs(dbPath)) {
    const candidates = buffer[0] === 0x7b ? [buffer.toString('utf8')] : collectStrings(buffer, 0, []);
    for (const candidate of candidates) {
      const trimmed = candidate.trim();
      if (!trimmed.startsWith('{')) continue;
      let blob;
      try {
        blob = JSON.parse(trimmed);
      } catch {
        continue;
      }
      if (!blob || (blob.role !== 'user' && blob.role !== 'assistant')) continue;
      const text = stripLeadingBlocks(extractContent(blob.content));
      if (!text || isInjectedContext(text)) continue;
      const key = blob.id || text.slice(0, 300);
      if (seen.has(key)) continue;
      seen.add(key);
      messages.push({ role: blob.role, text, timestamp: null });
    }
  }
  return messages;
};

const parseFile = async (chatDir) => {
  let meta = {};
  try {
    meta = JSON.parse(fs.readFileSync(path.join(chatDir, 'meta.json'), 'utf8'));
  } catch {
    meta = {};
  }
  const messages = readMessages(path.join(chatDir, 'store.db'));
  const stats = fs.statSync(path.join(chatDir, 'store.db'));
  return {
    id: path.basename(chatDir),
    tool: 'cursor',
    title: meta.title || firstPrompt(messages) || 'Untitled session',
    cwd: meta.cwd || '',
    filePath: chatDir,
    startedAt: meta.createdAtMs ?? stats.birthtimeMs,
    updatedAt: meta.updatedAtMs ?? stats.mtimeMs,
    messageCount: messages.length,
    preview: collapse(firstPrompt(messages)),
    searchText: buildSearchText(messages),
    messages,
  };
};

const resumeCommand = (session) => {
  const target = session.cwd ? `cd ${JSON.stringify(session.cwd)} && ` : '';
  return `${target}cursor-agent --resume=${session.id}`;
};

module.exports = { tool: 'cursor', listFiles, parseFile, resumeCommand };
