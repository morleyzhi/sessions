const listElement = document.getElementById('list');
const detailElement = document.getElementById('detail');
const countElement = document.getElementById('count');
const queryElement = document.getElementById('query');
const filtersElement = document.getElementById('filters');

let allSessions = [];
let visibleSessions = [];
let activeTool = 'all';
let selectedKey = '';
let liveKeys = new Set();
let detailKey = '';

const escapeHtml = (value) =>
  String(value).replace(/[&<>"']/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[character]);

const highlight = (text, terms) => {
  let output = escapeHtml(text);
  for (const term of terms) {
    if (!term) continue;
    const pattern = new RegExp(term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi');
    output = output.replace(pattern, (match) => `<mark>${match}</mark>`);
  }
  return output;
};

const relativeTime = (timestamp) => {
  const minutes = Math.round((Date.now() - timestamp) / 60000);
  if (minutes < 1) return 'just now';
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.round(hours / 24);
  if (days < 30) return `${days}d ago`;
  return new Date(timestamp).toLocaleDateString();
};

const TOOL_NAMES = { claude: 'Claude', codex: 'Codex', cursor: 'Cursor' };

const toolPill = (tool) =>
  `<span class="pill"><span class="dot ${escapeHtml(tool)}"></span>${escapeHtml(TOOL_NAMES[tool] || tool)}</span>`;

const keyOf = (session) => `${session.tool}:${session.id}`;

const render = () => {
  const terms = queryElement.value.toLowerCase().split(/\s+/).filter(Boolean);
  visibleSessions = allSessions.filter((session) => activeTool === 'all' || session.tool === activeTool);
  countElement.textContent = `${visibleSessions.length} session${visibleSessions.length === 1 ? '' : 's'}`;

  listElement.innerHTML = visibleSessions
    .map((session) => {
      const snippet = session.snippet || session.preview;
      const live = liveKeys.has(keyOf(session));
      return `<li class="row ${keyOf(session) === selectedKey ? 'selected' : ''}" draggable="true" data-key="${escapeHtml(keyOf(session))}">
        <div class="row-top">
          <span class="dot ${session.tool}"></span>
          <span class="row-title">${highlight(session.title, terms)}</span>
          ${live ? '<span class="live-tag" title="A running CLI owns this session, so it cannot be resumed until you quit it">live</span>' : ''}
        </div>
        <div class="row-meta">
          <span>${escapeHtml(session.project || '—')}</span>
          <span>${session.messageCount} msgs</span>
          <span>${relativeTime(session.updatedAt)}</span>
        </div>
        ${snippet ? `<div class="row-snippet">${highlight(snippet, terms)}</div>` : ''}
      </li>`;
    })
    .join('');
};

const renderDetail = (session, summary) => {
  const live = liveKeys.has(keyOf(summary));
  const messages = session.messages
    .map(
      (message) => `<div class="message ${message.role} ${message.isSidechain ? 'sidechain' : ''}">
        <div class="role">${message.role}${message.isSidechain ? ' · subagent' : ''}</div>
        <div class="bubble">${escapeHtml(message.text)}</div>
      </div>`
    )
    .join('');

  detailElement.innerHTML = `
    <div class="detail-header">
      <h1>${escapeHtml(session.title)}</h1>
      <div class="detail-sub">
        ${toolPill(session.tool)}
        <span>${escapeHtml(session.cwd || 'no working directory')}</span>
        <span>${new Date(session.updatedAt).toLocaleString()}</span>
        <span>${session.messageCount} messages</span>
      </div>
      ${live ? `<div class="notice">This session is open in a running ${toolPill(session.tool)}. Resuming it will fail until you quit that process.</div>` : ''}
      <div class="resume">
        <code id="resume-command">${escapeHtml(session.resumeCommand)}</code>
        <button class="copy" id="copy">Copy resume command</button>
      </div>
    </div>
    <div class="messages">${messages || '<div class="empty">No readable messages</div>'}</div>`;

  document.getElementById('copy').addEventListener('click', async (event) => {
    await window.sessions.copyResume(summary);
    event.target.textContent = 'Copied — paste in iTerm2';
    event.target.classList.add('done');
    setTimeout(() => {
      event.target.textContent = 'Copy resume command';
      event.target.classList.remove('done');
    }, 2000);
  });
};

const select = async (key) => {
  // Clicking the row already shown in the detail pane does nothing.
  if (key === detailKey) return;
  const summary = visibleSessions.find((session) => keyOf(session) === key);
  if (!summary) return;
  selectedKey = key;
  render();
  detailElement.innerHTML = '<div class="empty">Loading…</div>';
  const session = await window.sessions.open({ tool: summary.tool, filePath: summary.filePath });
  if (selectedKey !== key) return;
  if (!session) {
    detailElement.innerHTML = '<div class="empty">Could not read this session</div>';
    return;
  }
  detailKey = key;
  renderDetail(session, summary);
};

listElement.addEventListener('click', (event) => {
  const row = event.target.closest('.row');
  if (row) select(row.dataset.key);
});

listElement.addEventListener('contextmenu', (event) => {
  const row = event.target.closest('.row');
  if (!row) return;
  event.preventDefault();
  const session = visibleSessions.find((candidate) => keyOf(candidate) === row.dataset.key);
  if (session) window.sessions.contextMenu(session);
});

// Dropping a row on iTerm2 pastes the resume command; the trailing newline runs it.
listElement.addEventListener('dragstart', (event) => {
  const row = event.target.closest('.row');
  const session = row && visibleSessions.find((candidate) => keyOf(candidate) === row.dataset.key);
  if (!session || !session.resumeCommand) return;
  event.dataTransfer.setData('text/plain', `${session.resumeCommand}\n`);
  event.dataTransfer.effectAllowed = 'copy';
  row.classList.add('dragging');
});

listElement.addEventListener('dragend', (event) => {
  event.target.closest('.row')?.classList.remove('dragging');
});

filtersElement.addEventListener('click', (event) => {
  const button = event.target.closest('.filter');
  if (!button) return;
  activeTool = button.dataset.tool;
  for (const filter of filtersElement.children) filter.classList.toggle('active', filter === button);
  render();
});

let searchTimer = null;
queryElement.addEventListener('input', () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(async () => {
    allSessions = await window.sessions.search(queryElement.value);
    render();
  }, 120);
});

window.sessions.onLive((keys) => {
  const next = new Set(keys);
  if (next.size === liveKeys.size && [...next].every((key) => liveKeys.has(key))) return;
  liveKeys = next;
  render();
});

window.sessions.onProgress(({ done, total }) => {
  countElement.textContent = `Indexing ${done} / ${total}…`;
});

window.sessions.list().then((sessions) => {
  allSessions = sessions;
  render();
});
