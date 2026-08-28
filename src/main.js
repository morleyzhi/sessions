const path = require('path');
const { app, BrowserWindow, ipcMain, clipboard } = require('electron');
const { buildIndex, loadSession, resumeCommandFor } = require('./indexers');

let mainWindow = null;
let sessions = [];

const cachePath = () => path.join(app.getPath('userData'), 'index.json');

const createWindow = () => {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 820,
    minWidth: 900,
    titleBarStyle: 'hiddenInset',
    backgroundColor: '#16171b',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });
  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));
};

const refresh = async () => {
  sessions = await buildIndex({
    cachePath: cachePath(),
    onProgress: (progress) => mainWindow?.webContents.send('index-progress', progress),
  });
  return sessions.map(({ searchText, ...summary }) => summary);
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
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

ipcMain.handle('sessions:list', () => refresh());

ipcMain.handle('sessions:search', (event, query) => {
  const terms = String(query || '').toLowerCase().split(/\s+/).filter(Boolean);
  if (!terms.length) return sessions.map(({ searchText, ...summary }) => summary);
  return sessions
    .filter((session) => matches(session, terms))
    .map(({ searchText, ...summary }) => ({ ...summary, snippet: snippetFor(session, terms) }));
});

ipcMain.handle('sessions:open', (event, { tool, filePath }) => loadSession({ tool, filePath }));

ipcMain.handle('sessions:copyResume', (event, summary) => {
  const command = resumeCommandFor(summary);
  clipboard.writeText(command);
  return command;
});
