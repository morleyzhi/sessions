const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('sessions', {
  list: () => ipcRenderer.invoke('sessions:list'),
  search: (query) => ipcRenderer.invoke('sessions:search', query),
  open: (target) => ipcRenderer.invoke('sessions:open', target),
  copyResume: (summary) => ipcRenderer.invoke('sessions:copyResume', summary),
  onLive: (handler) => ipcRenderer.on('live-sessions', (event, keys) => handler(keys)),
  onProgress: (handler) => ipcRenderer.on('index-progress', (event, progress) => handler(progress)),
});
