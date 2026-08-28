const path = require('path');
const { app, BrowserWindow, ipcMain, clipboard } = require('electron');
const { buildIndex, loadSession, resumeCommandFor } = require('./indexers');
const { liveSessionKeys } = require('./live');

let mainWindow = null;
let sessions = [];

const cachePath = () => path.join(app.getPath('userData'), 'index.json');

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

const refresh = async () => {
  sessions = await buildIndex({
    cachePath: cachePath(),
    onProgress: (progress) => mainWindow?.webContents.send('index-progress', progress),
  });
  return sessions.map(summarize);
};

// Push the set of running sessions to the window so rows can mark themselves.
const sendLiveKeys = () => {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  mainWindow.webContents.send('live-sessions', [...liveSessionKeys(sessions)]);
};

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
  createWindow();
  setInterval(sendLiveKeys, 5000);
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

ipcMain.handle('sessions:list', async () => {
  const summaries = await refresh();
  sendLiveKeys();
  return summaries;
});

ipcMain.handle('sessions:search', (event, query) => {
  const terms = String(query || '').toLowerCase().split(/\s+/).filter(Boolean);
  if (!terms.length) return sessions.map(summarize);
  return sessions
    .filter((session) => matches(session, terms))
    .map((session) => {
      return { ...summarize(session), snippet: snippetFor(session, terms) };
    });
});

ipcMain.handle('sessions:open', (event, { tool, filePath }) => loadSession({ tool, filePath }));

ipcMain.handle('sessions:copyResume', (event, summary) => {
  const command = resumeCommandFor(summary);
  clipboard.writeText(command);
  return command;
});
