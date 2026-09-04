const fs = require('fs');
const path = require('path');
const { app, BrowserWindow, Menu, ipcMain, clipboard } = require('electron');
const { buildIndex, loadSession, resumeCommandFor } = require('./indexers');
const { liveSessionKeys } = require('./live');

let mainWindow = null;
let sessions = [];

const cachePath = () => path.join(app.getPath('userData'), 'index.json');
const pinsPath = () => path.join(app.getPath('userData'), 'pins.json');

// Sessions you pinned, newest pin first. Kept as keys, so a pin outlives a re-index.
let pinnedKeys = [];

const loadPins = () => {
  try {
    const stored = JSON.parse(fs.readFileSync(pinsPath(), 'utf8'));
    pinnedKeys = Array.isArray(stored) ? stored.filter((key) => typeof key === 'string') : [];
  } catch {
    pinnedKeys = [];
  }
};

const togglePin = (key) => {
  pinnedKeys = pinnedKeys.includes(key) ? pinnedKeys.filter((pin) => pin !== key) : [key, ...pinnedKeys];
  try {
    fs.writeFileSync(pinsPath(), JSON.stringify(pinnedKeys));
  } catch {
    // A pin that cannot be written still holds for this run.
  }
  mainWindow?.webContents.send('pins-updated', pinnedKeys);
  return pinnedKeys;
};

const createWindow = () => {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 820,
    minWidth: 900,
    titleBarStyle: 'hiddenInset',
    backgroundColor: '#0e0f12',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });
  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));
};

const summarize = (session) => {
  const { searchText, ...summary } = session;
  return summary;
};

const refresh = async ({ quiet = false } = {}) => {
  sessions = await buildIndex({
    cachePath: cachePath(),
    onProgress: (progress) => {
      if (!quiet) mainWindow?.webContents.send('index-progress', progress);
    },
  });
  return sessions.map(summarize);
};

// What the window is currently showing, so a poll that changed nothing is silent.
const signatureOf = (summaries) =>
  summaries.map((summary) => `${summary.tool}:${summary.id}:${summary.updatedAt}`).join(',');

let signature = '';
let polling = false;

/**
 * Re-read the transcripts so a session started after launch shows up, then mark
 * the running ones. Without the re-read a new session is missing from the index
 * and can never be marked live.
 */
const poll = async () => {
  if (polling || !mainWindow || mainWindow.isDestroyed()) return;
  polling = true;
  try {
    const summaries = await refresh({ quiet: true });
    if (signatureOf(summaries) !== signature) {
      signature = signatureOf(summaries);
      mainWindow.webContents.send('sessions-updated', summaries);
    }
    sendLiveKeys();
  } finally {
    polling = false;
  }
};

// Push the set of running sessions to the window so rows can mark themselves.
const sendLiveKeys = () => {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  mainWindow.webContents.send('live-sessions', [...liveSessionKeys(sessions)]);
};

/**
 * Split a query into terms. Every term has to appear somewhere in the session,
 * and a quoted run stays one term, so "chain together" matches only that phrase.
 */
const queryTerms = (query) =>
  (String(query || '')
    .toLowerCase()
    .match(/"[^"]*"?|\S+/g) || [])
    .map((term) => term.replace(/"/g, '').trim())
    .filter(Boolean);

const matches = (session, terms) => {
  const haystack = `${session.title}\n${session.cwd}\n${session.searchText}`.toLowerCase();
  return terms.every((term) => haystack.includes(term));
};

const snippetFor = (session, terms) => {
  const haystack = session.searchText;
  const position = haystack.toLowerCase().indexOf(terms[0]);
  if (position === -1) return session.preview;
  const start = Math.max(0, position - 60);
  return `${start > 0 ? '…' : ''}${haystack.slice(start, position + 140).replace(/\s+/g, ' ')}…`;
};

app.whenReady().then(() => {
  loadPins();
  createWindow();
  setInterval(poll, 3000);
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

ipcMain.handle('sessions:list', async () => {
  const summaries = await refresh();
  signature = signatureOf(summaries);
  sendLiveKeys();
  return summaries;
});

ipcMain.handle('sessions:search', (event, query) => {
  const terms = queryTerms(query);
  if (!terms.length) return sessions.map(summarize);
  return sessions
    .filter((session) => matches(session, terms))
    .map((session) => {
      return { ...summarize(session), snippet: snippetFor(session, terms) };
    });
});

ipcMain.handle('sessions:open', (event, { tool, filePath }) => loadSession({ tool, filePath }));

ipcMain.on('sessions:contextMenu', (event, summary) => {
  const copyItem = (label, value) => ({
    label,
    enabled: Boolean(value),
    click: () => clipboard.writeText(String(value)),
  });
  const key = `${summary.tool}:${summary.id}`;
  const menu = Menu.buildFromTemplate([
    { label: pinnedKeys.includes(key) ? 'Unpin' : 'Pin to Top', click: () => togglePin(key) },
    { type: 'separator' },
    copyItem('Copy Command', summary.resumeCommand),
    { type: 'separator' },
    copyItem('Copy Title', summary.title),
    copyItem('Copy Session ID', summary.id),
    copyItem('Copy Working Directory', summary.cwd),
    copyItem('Copy Transcript Path', summary.filePath),
  ]);
  menu.popup({ window: BrowserWindow.fromWebContents(event.sender) });
});

ipcMain.handle('pins:list', () => pinnedKeys);

ipcMain.handle('pins:toggle', (event, key) => togglePin(String(key)));

ipcMain.handle('sessions:copyResume', (event, summary) => {
  const command = resumeCommandFor(summary);
  clipboard.writeText(command);
  return command;
});
