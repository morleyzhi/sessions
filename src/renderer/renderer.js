const listElement = document.getElementById('list');
const pinnedElement = document.getElementById('pinned');
const detailElement = document.getElementById('detail');
const queryElement = document.getElementById('query');
const filtersElement = document.getElementById('filters');

let allSessions = [];
let visibleSessions = [];
let activeTool = 'all';
let selectedKey = '';
let liveKeys = new Set();
let pinnedKeys = new Set();
let detailKey = '';

const escapeHtml = (value) =>
  String(value).replace(/[&<>"']/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[character]);

// Split a query the same way the search does: a quoted run stays one term.
const queryTerms = (query) =>
  (String(query || '')
    .toLowerCase()
    .match(/"[^"]*"?|\S+/g) || [])
    .map((term) => term.replace(/"/g, '').trim())
    .filter(Boolean);

// Format inline text and open web links in the default browser.
// Code spans are pulled out first so that bold wrapped around one still pairs up.
const inlineMarkdown = (text) => {
  const codeSpans = [];
  const links = [];
  const link = (url, label) => {
    const short = url.replace(/^https?:\/\//, '');
    const slash = short.indexOf('/');
    const display = slash !== -1 && short.length - slash - 1 > 10
      ? `${short.slice(0, slash + 1)}…${short.slice(-10)}` : short;
    links.push(`<a href="${escapeHtml(url)}" title="${escapeHtml(url)}">${escapeHtml(label && !/^https?:\/\//.test(label) ? label : display)}</a>`);
    return `${links.length - 1}`;
  };
  let out = String(text).replace(/`([^`]+)`/g, (match, code) => {
    codeSpans.push(code);
    return `${codeSpans.length - 1}`;
  });
  out = out.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, (match, label, url) => link(url, label));
  out = out.replace(/https?:\/\/[^\s<>"']+/g, (url) => {
    const clean = url.replace(/[.,;:!?]+$/, '').replace(/\)+$/, (tail) => {
      const extra = Math.max(0, (url.match(/\)/g) || []).length - (url.match(/\(/g) || []).length);
      return tail.slice(0, Math.max(0, tail.length - extra));
    });
    return link(clean) + url.slice(clean.length);
  });
  out = escapeHtml(out);
  out = out.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  out = out.replace(/(^|[\s(])\*([^*\n]+)\*/g, '$1<em>$2</em>');
  out = out.replace(/(^|[\s(])_([^_\n]+)_/g, '$1<em>$2</em>');
  out = out.replace(/~~([^~]+)~~/g, '<del>$1</del>');
  return out.replace(/(\d+)/g, (match, index) => `<code>${escapeHtml(codeSpans[Number(index)])}</code>`)
    .replace(/(\d+)/g, (match, index) => links[Number(index)]);
};

const tableCells = (line) =>
  line
    .trim()
    .replace(/^\|/, '')
    .replace(/\|$/, '')
    .split('|')
    .map((cell) => cell.trim());

const isTableRow = (line) => /^\s*\|/.test(line);

const isTableRule = (line) => /^\s*\|?[\s:|-]*-[\s:|-]*$/.test(line) && line.includes('-');

// Enough markdown for a transcript: fenced code, tables, headings, lists, quotes, rules.
const markdown = (text) => {
  const lines = String(text).split('\n');
  const html = [];
  let paragraph = [];
  let list = null;
  let fence = null;

  const closeParagraph = () => {
    if (!paragraph.length) return;
    html.push(`<p>${paragraph.map(inlineMarkdown).join('<br>')}</p>`);
    paragraph = [];
  };
  const closeList = () => {
    if (!list) return;
    const items = list.items.map((item) => `<li>${inlineMarkdown(item)}</li>`).join('');
    html.push(`<${list.tag}>${items}</${list.tag}>`);
    list = null;
  };
  const closeAll = () => {
    closeParagraph();
    closeList();
  };

  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    const fenceMatch = /^\s*```/.test(line);
    if (fence) {
      if (fenceMatch) {
        html.push(`<pre><code>${escapeHtml(fence.join('\n'))}</code></pre>`);
        fence = null;
      } else fence.push(line);
      continue;
    }
    if (fenceMatch) {
      closeAll();
      fence = [];
      continue;
    }
    if (!line.trim()) {
      closeAll();
      continue;
    }
    if (isTableRow(line) && isTableRule(lines[index + 1] || '')) {
      closeAll();
      const header = tableCells(line);
      const rows = [];
      let next = index + 2;
      while (next < lines.length && isTableRow(lines[next])) {
        rows.push(tableCells(lines[next]));
        next++;
      }
      index = next - 1;
      const head = header.map((cell) => `<th>${inlineMarkdown(cell)}</th>`).join('');
      const body = rows
        .map((row) => `<tr>${row.map((cell) => `<td>${inlineMarkdown(cell)}</td>`).join('')}</tr>`)
        .join('');
      html.push(`<div class="md-table"><table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`);
      continue;
    }
    const heading = line.match(/^(#{1,6})\s+(.*)$/);
    if (heading) {
      closeAll();
      html.push(`<div class="md-h md-h${heading[1].length}">${inlineMarkdown(heading[2])}</div>`);
      continue;
    }
    if (/^\s*([-*_])\s*\1\s*\1[-*_\s]*$/.test(line)) {
      closeAll();
      html.push('<hr>');
      continue;
    }
    const quote = line.match(/^\s*>\s?(.*)$/);
    if (quote) {
      closeAll();
      html.push(`<blockquote>${inlineMarkdown(quote[1])}</blockquote>`);
      continue;
    }
    const bullet = line.match(/^\s*[-*+]\s+(.*)$/);
    const numbered = line.match(/^\s*\d+[.)]\s+(.*)$/);
    if (bullet || numbered) {
      closeParagraph();
      const tag = bullet ? 'ul' : 'ol';
      if (!list || list.tag !== tag) {
        closeList();
        list = { tag, items: [] };
      }
      list.items.push((bullet || numbered)[1]);
      continue;
    }
    closeList();
    paragraph.push(line);
  }
  if (fence) html.push(`<pre><code>${escapeHtml(fence.join('\n'))}</code></pre>`);
  closeAll();
  return html.join('');
};

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

// When a turn was written. The date is dropped for a turn from today.
const turnTime = (timestamp) => {
  const date = new Date(timestamp);
  const time = date.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  if (date.toDateString() === new Date().toDateString()) return time;
  return `${date.toLocaleDateString([], { month: 'short', day: 'numeric' })}, ${time}`;
};

const TOOL_NAMES = { claude: 'Claude', codex: 'Codex', cursor: 'Cursor' };

const toolPill = (tool) =>
  `<span class="pill"><span class="dot ${escapeHtml(tool)}"></span>${escapeHtml(TOOL_NAMES[tool] || tool)}</span>`;

const keyOf = (session) => `${session.tool}:${session.id}`;

const PIN_ICON =
  '<svg class="pin-icon" viewBox="0 0 24 24" aria-hidden="true">' +
  '<path d="M12 17v5" />' +
  '<path d="M9 10.8a2 2 0 0 1-1.1 1.8l-1.8.9A2 2 0 0 0 5 15.2V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.8a2 2 0 0 0-1.1-1.8l-1.8-.9a2 2 0 0 1-1.1-1.8V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z" />' +
  '</svg>';

const rowContent = (session, terms) => {
  const snippet = session.snippet || session.preview;
  const key = keyOf(session);
  const live = liveKeys.has(key);
  const pinned = pinnedKeys.has(key);
  return `<div class="row-top">
      <span class="dot ${session.tool}"></span>
      <span class="row-title">${highlight(session.title, terms)}</span>
      ${live ? '<span class="live-tag" title="A running CLI owns this session, so it cannot be resumed until you quit it">live</span>' : ''}
      <button class="pin ${pinned ? 'on' : ''}" title="${pinned ? 'Unpin' : 'Pin to top'}">${PIN_ICON}</button>
    </div>
    <div class="row-meta">
      <span>${escapeHtml(session.project || '—')}</span>
      <span>${relativeTime(session.updatedAt)}</span>
    </div>
    ${snippet ? `<div class="row-snippet">${highlight(snippet, terms)}</div>` : ''}`;
};

/**
 * Update one list in place, matching rows by key. Rewriting the whole list on
 * every poll made rows flicker as a live session re-sorted to the top; here an
 * unchanged row is only moved, and a moved row is not repainted.
 */
const renderList = (element, sessions, terms) => {
  const existing = new Map();
  for (const row of element.children) existing.set(row.dataset.key, row);

  let cursor = element.firstElementChild;
  for (const session of sessions) {
    const key = keyOf(session);
    let row = existing.get(key);
    if (!row) {
      row = document.createElement('li');
      row.className = 'row';
      row.draggable = true;
      row.dataset.key = key;
    }
    if (row === cursor) cursor = cursor.nextElementSibling;
    else element.insertBefore(row, cursor);

    const content = rowContent(session, terms);
    if (row.renderedContent !== content) {
      row.innerHTML = content;
      row.renderedContent = content;
    }
    row.classList.toggle('selected', key === selectedKey);
  }

  while (cursor) {
    const next = cursor.nextElementSibling;
    cursor.remove();
    cursor = next;
  }
};

const render = () => {
  const terms = queryTerms(queryElement.value);
  visibleSessions = allSessions.filter((session) => activeTool === 'all' || session.tool === activeTool);
  // Pinned sessions sit above the rest, in the order you pinned them.
  const order = [...pinnedKeys];
  const pinned = visibleSessions
    .filter((session) => pinnedKeys.has(keyOf(session)))
    .sort((left, right) => order.indexOf(keyOf(left)) - order.indexOf(keyOf(right)));
  renderList(pinnedElement, pinned, terms);
  renderList(listElement, visibleSessions.filter((session) => !pinnedKeys.has(keyOf(session))), terms);
};

// Consecutive assistant messages and their tools share one fold control.
const groupTurns = (messages) => {
  const groups = [];
  for (const [messageIndex, message] of messages.entries()) {
    if (message.toolCalls && !message.toolCalls.length) continue;
    const role = message.toolCalls ? 'assistant' : message.role;
    const last = groups[groups.length - 1];
    if (role === 'assistant' && last?.role === role && last.isSidechain === message.isSidechain) {
      last.messages.push(message);
    } else {
      groups.push({ messageIndex, role, timestamp: message.timestamp, isSidechain: message.isSidechain, messages: [message] });
    }
  }
  return groups;
};

const renderTools = (group) => {
  const label = group.calls.length === 1 ? '1 tool call' : `${group.calls.length} tool calls`;
  const names = [...new Set(group.calls.map((call) => call.name))].slice(0, 4).join(', ');
  const rows = group.calls
    .map(
      (call) => `<div class="tool-call">
        <span class="tool-name">${escapeHtml(call.name)}</span>
        <span class="tool-summary">${escapeHtml(call.summary)}</span>
      </div>`
    )
    .join('');
  return `<details class="tools">
    <summary>
      <span class="tool-caret">▸</span>
      <span class="tool-label">${label}</span>
      <span class="tool-names">${escapeHtml(names)}</span>
    </summary>
    <div class="tool-body">${rows}</div>
  </details>`;
};

const renderMessage = (turn) => `<details open data-message-index="${turn.messageIndex}" class="message ${escapeHtml(turn.role)} ${turn.isSidechain ? 'sidechain' : ''}">
  <summary class="role" title="Fold or unfold this turn">
    <span class="turn-caret">▸</span>
    <span>${escapeHtml(turn.role)}${turn.isSidechain ? ' · subagent' : ''}</span>
    ${turn.timestamp ? `<span class="turn-time">${turnTime(turn.timestamp)}</span>` : ''}
  </summary>
  <div class="turn-content bubble">${turn.messages.map((message) => message.toolCalls
    ? renderTools({ calls: message.toolCalls })
    : `<div class="turn-text">${markdown(message.text)}</div>`).join('')}</div>
  <button class="turn-expand" aria-expanded="false" hidden>Expand</button>
</details>`;

const updateTurns = () => {
  for (const turn of detailElement.querySelectorAll('.message[open]')) {
    const content = turn.querySelector('.turn-content');
    const long = content.scrollHeight + 2 > 600;
    turn.classList.toggle('long', long);
    turn.querySelector('.turn-expand').hidden = !long;
  }
  updateBottomButton();
};

const updateBottomButton = () => {
  const button = detailElement.querySelector('.scroll-bottom');
  if (button) button.hidden = detailElement.scrollHeight - detailElement.scrollTop - detailElement.clientHeight <= 32;
};

const expandTurn = (turn, expanded) => {
  turn.classList.toggle('expanded', expanded);
  const button = turn.querySelector('.turn-expand');
  button.textContent = expanded ? 'Retract' : 'Expand';
  button.setAttribute('aria-expanded', String(expanded));
};

const detailResizeObserver = new ResizeObserver(updateTurns);
detailResizeObserver.observe(detailElement);
detailElement.addEventListener('scroll', updateBottomButton);
detailElement.addEventListener('toggle', updateTurns, true);
detailElement.addEventListener('click', (event) => {
  const link = event.target.closest('a[href]');
  if (link) {
    event.preventDefault();
    window.sessions.openLink(link.href);
  }
  const expand = event.target.closest('.turn-expand');
  if (expand) {
    const turn = expand.closest('.message');
    expandTurn(turn, !turn.classList.contains('expanded'));
    if (!turn.classList.contains('expanded')) turn.scrollIntoView({ block: 'nearest' });
    updateBottomButton();
  }
  if (event.target.closest('.scroll-bottom')) detailElement.scrollTo({ top: detailElement.scrollHeight, behavior: 'smooth' });
});

// The rendered turns of the open session, kept so a find can rebuild them.
let messagesHtml = '';
let findMarks = [];
let findIndex = 0;

const findCountElement = () => document.getElementById('find-count');

const focusMatch = (index) => {
  if (!findMarks.length) return;
  findIndex = (index + findMarks.length) % findMarks.length;
  findMarks.forEach((mark, position) => mark.classList.toggle('current', position === findIndex));
  const mark = findMarks[findIndex];
  for (let parent = mark.parentElement; parent && parent !== detailElement; parent = parent.parentElement) {
    if (parent.tagName === 'DETAILS') parent.open = true;
  }
  updateTurns();
  const turn = mark.closest('.message');
  const content = turn?.querySelector('.turn-content');
  if (turn?.classList.contains('long') && mark.getBoundingClientRect().bottom > content.getBoundingClientRect().bottom - 64) {
    expandTurn(turn, true);
  }
  mark.scrollIntoView({ block: 'center' });
  updateBottomButton();
  findCountElement().textContent = `${findIndex + 1} of ${findMarks.length}`;
};

// Search all turn text, including folded and shortened content.
const applyFind = (term) => {
  const messagesElement = detailElement.querySelector('.messages');
  if (!messagesElement) return;
  messagesElement.innerHTML = messagesHtml;
  findMarks = [];
  findIndex = 0;
  const count = findCountElement();
  const needle = term.toLowerCase();
  if (!needle) {
    count.textContent = '';
    updateTurns();
    return;
  }

  const walker = document.createTreeWalker(messagesElement, NodeFilter.SHOW_TEXT);
  const targets = [];
  while (walker.nextNode()) {
    if (walker.currentNode.nodeValue.toLowerCase().includes(needle)) targets.push(walker.currentNode);
  }

  for (const node of targets) {
    const text = node.nodeValue;
    const fragment = document.createDocumentFragment();
    let position = 0;
    let at = text.toLowerCase().indexOf(needle);
    while (at !== -1) {
      fragment.appendChild(document.createTextNode(text.slice(position, at)));
      const mark = document.createElement('mark');
      mark.className = 'find';
      mark.textContent = text.slice(at, at + term.length);
      fragment.appendChild(mark);
      findMarks.push(mark);
      position = at + term.length;
      at = text.toLowerCase().indexOf(needle, position);
    }
    fragment.appendChild(document.createTextNode(text.slice(position)));
    node.parentNode.replaceChild(fragment, node);
  }

  updateTurns();
  if (!findMarks.length) {
    count.textContent = 'no matches';
    return;
  }
  focusMatch(0);
};

const renderDetail = (session, summary) => {
  const live = liveKeys.has(keyOf(summary));
  messagesHtml =
    groupTurns(session.messages)
      .map(renderMessage)
      .join('') || '<div class="empty">No readable messages</div>';
  findMarks = [];

  detailElement.innerHTML = `
    <div class="detail-header">
      <h1>${escapeHtml(session.title)}</h1>
      <div class="detail-sub">
        ${toolPill(session.tool)}
        <span>${escapeHtml(session.cwd || 'no working directory')}</span>
        <span>${new Date(session.updatedAt).toLocaleString()}</span>
      </div>
      ${live ? `<div class="notice">This session is open in a running ${toolPill(session.tool)}. Resuming it will fail until you quit that process.</div>` : ''}
      <div class="resume">
        <code id="resume-command">${escapeHtml(session.resumeCommand)}</code>
        <button class="copy" id="copy">Copy resume command</button>
      </div>
      <div class="find">
        <input id="find" type="search" placeholder="Find in this session" spellcheck="false" />
        <span class="find-count" id="find-count"></span>
        <button class="find-step" id="find-prev" title="Previous match">↑</button>
        <button class="find-step" id="find-next" title="Next match">↓</button>
      </div>
    </div>
    <div class="messages">${messagesHtml}</div>
    <button class="scroll-bottom" hidden>↓ Scroll to bottom</button>`;
  detailResizeObserver.disconnect();
  detailResizeObserver.observe(detailElement);
  detailResizeObserver.observe(detailElement.querySelector('.messages'));
  updateTurns();

  const findElement = document.getElementById('find');
  let findTimer = null;
  findElement.addEventListener('input', () => {
    clearTimeout(findTimer);
    findTimer = setTimeout(() => applyFind(findElement.value), 120);
  });
  findElement.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      findElement.value = '';
      applyFind('');
      return;
    }
    if (event.key !== 'Enter') return;
    event.preventDefault();
    focusMatch(findIndex + (event.shiftKey ? -1 : 1));
  });
  document.getElementById('find-prev').addEventListener('click', () => focusMatch(findIndex - 1));
  document.getElementById('find-next').addEventListener('click', () => focusMatch(findIndex + 1));

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

const setPins = (keys) => {
  pinnedKeys = new Set(keys);
  render();
};

const select = async (key, targetSummary = null) => {
  // Clicking the row already shown in the detail pane does nothing.
  if (key === detailKey && !targetSummary) return;
  const summary = targetSummary || visibleSessions.find((session) => keyOf(session) === key);
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

const attachRowHandlers = (element) => {
  element.addEventListener('click', async (event) => {
    const row = event.target.closest('.row');
    if (!row) return;
    if (event.target.closest('.pin')) {
      setPins(await window.sessions.togglePin(row.dataset.key));
      return;
    }
    select(row.dataset.key);
  });

  element.addEventListener('contextmenu', (event) => {
    const row = event.target.closest('.row');
    if (!row) return;
    event.preventDefault();
    const session = visibleSessions.find((candidate) => keyOf(candidate) === row.dataset.key);
    if (session) window.sessions.contextMenu(session);
  });

  // Dropping a row on iTerm2 pastes the resume command; the trailing newline runs it.
  element.addEventListener('dragstart', (event) => {
    const row = event.target.closest('.row');
    const session = row && visibleSessions.find((candidate) => keyOf(candidate) === row.dataset.key);
    if (!session || !session.resumeCommand) return;
    event.dataTransfer.setData('text/plain', `${session.resumeCommand}\n`);
    event.dataTransfer.effectAllowed = 'copy';
    row.classList.add('dragging');
  });

  element.addEventListener('dragend', (event) => {
    event.target.closest('.row')?.classList.remove('dragging');
  });
};

attachRowHandlers(pinnedElement);
attachRowHandlers(listElement);

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

// A session started after launch arrives here, so it can be listed and marked live.
window.sessions.onSessions(async (sessions) => {
  allSessions = queryElement.value.trim() ? await window.sessions.search(queryElement.value) : sessions;
  render();
});

window.sessions.onLive((keys) => {
  const next = new Set(keys);
  if (next.size === liveKeys.size && [...next].every((key) => liveKeys.has(key))) return;
  liveKeys = next;
  render();
});

window.sessions.onProgress(({ done, total }) => {
  queryElement.placeholder = done < total ? `Indexing ${done} / ${total}…` : 'Search sessions';
});

document.addEventListener('keydown', (event) => {
  if (!(event.metaKey || event.ctrlKey) || event.key !== 'f') return;
  const find = document.getElementById('find');
  event.preventDefault();
  (find || queryElement).select();
});

window.sessions.onPins(setPins);

window.sessions.pins().then((keys) => {
  pinnedKeys = new Set(keys);
  render();
});

window.sessions.list().then((sessions) => {
  allSessions = sessions;
  render();
  document.dispatchEvent(new Event('sessions-loaded'));
});
