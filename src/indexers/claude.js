const fs = require('fs');
const path = require('path');
const os = require('os');
const readline = require('readline');
const {
  extractContent,
  buildSearchText,
  firstPrompt,
  lastMessageTime,
  collapse,
  isToolOnly,
  toolCalls,
} = require('./text');

const ROOT = path.join(os.homedir(), '.claude', 'projects');

const listFiles = () => {
  if (!fs.existsSync(ROOT)) return [];
  const files = [];
  for (const project of fs.readdirSync(ROOT)) {
    const dir = path.join(ROOT, project);
    if (!fs.statSync(dir).isDirectory()) continue;
    for (const entry of fs.readdirSync(dir)) {
      if (entry.endsWith('.jsonl')) files.push(path.join(dir, entry));
    }
  }
  return files;
};

const isNoise = (text) =>
  text.startsWith('<local-command-caveat>') ||
  text.startsWith('<command-name>') ||
  text.startsWith('<command-message>') ||
  text.startsWith('Caveat: The messages below');

const parseFile = async (filePath) => {
  const stream = readline.createInterface({ input: fs.createReadStream(filePath), crlfDelay: Infinity });
  const messages = [];
  let aiTitle = '';
  let customTitle = '';
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
    if (event.cwd && !cwd) cwd = event.cwd;
    if (event.type === 'ai-title' && event.aiTitle) aiTitle = event.aiTitle;
    // A name you typed with /rename outranks the one Claude wrote for you.
    if (event.type === 'custom-title' && event.customTitle) customTitle = event.customTitle;
    if (event.timestamp) {
      const time = Date.parse(event.timestamp);
      if (!Number.isNaN(time)) {
        if (startedAt === null || time < startedAt) startedAt = time;
        if (updatedAt === null || time > updatedAt) updatedAt = time;
      }
    }
    if (event.type !== 'user' && event.type !== 'assistant') continue;
    if (event.isMeta) continue;
    const text = extractContent(event.message?.content).trim();
    if (!text || isNoise(text)) continue;
    messages.push({
      role: event.type,
      text,
      timestamp: event.timestamp ? Date.parse(event.timestamp) : null,
      isSidechain: Boolean(event.isSidechain),
      toolCalls: isToolOnly(text) ? toolCalls(text) : null,
    });
  }

  const stats = fs.statSync(filePath);
  const main = messages.filter((message) => !message.isSidechain);
  return {
    id: path.basename(filePath, '.jsonl'),
    tool: 'claude',
    title: customTitle || aiTitle || firstPrompt(main) || 'Untitled session',
    cwd: cwd || '',
    filePath,
    startedAt: startedAt ?? stats.birthtimeMs,
    updatedAt: lastMessageTime(main) ?? updatedAt ?? stats.mtimeMs,
    messageCount: main.length,
    preview: collapse(firstPrompt(main)),
    searchText: buildSearchText(main),
    messages,
  };
};

const resumeCommand = (session) => {
  const target = session.cwd ? `cd ${JSON.stringify(session.cwd)} && ` : '';
  return `${target}claude --resume ${session.id}`;
};

module.exports = { tool: 'claude', listFiles, parseFile, resumeCommand };
