const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('sessions', {
  list: () => ipcRenderer.invoke('sessions:list'),
  search: (query) => ipcRenderer.invoke('sessions:search', query),
  open: (target) => ipcRenderer.invoke('sessions:open', target),
  copyResume: (summary) => ipcRenderer.invoke('sessions:copyResume', summary),
  contextMenu: (summary) => ipcRenderer.send('sessions:contextMenu', summary),
  onSessions: (handler) => ipcRenderer.on('sessions-updated', (event, summaries) => handler(summaries)),
  onLive: (handler) => ipcRenderer.on('live-sessions', (event, keys) => handler(keys)),
  onProgress: (handler) => ipcRenderer.on('index-progress', (event, progress) => handler(progress)),
});
