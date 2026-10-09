const timelineView = document.getElementById('timeline-view');
const timelineScroll = document.getElementById('timeline-scroll');
const timelineCanvas = document.getElementById('timeline-canvas');
const timelineHead = document.getElementById('timeline-head');
const timelineStatus = document.getElementById('timeline-status');
let timelineRows = [];
const timelineZoom = document.getElementById('timeline-zoom');
let timelineScale = 1;
let timelineTimeScale = null;
let timelineHeight = 0;
let timelineLanes = [];
let timelineNow = Date.now();
let timelineLoaded = false;
let timelineRequest = 0;
let timelineFrame = null;
let timelineUntimed = 0;

const setMode = (mode) => {
  const timeline = mode === 'timeline';
  window.sessions.timelineMode(timeline);
  document.getElementById('sessions-view').hidden = timeline;
  timelineView.hidden = !timeline;
  document.getElementById('sessions-tab').setAttribute('aria-pressed', String(!timeline));
  document.getElementById('timeline-tab').setAttribute('aria-pressed', String(timeline));
  if (timeline) {
    if (!timelineLoaded) loadTimeline();
    else resizeTimeline();
  }
};

document.getElementById('sessions-tab').onclick = () => setMode('sessions');
document.getElementById('timeline-tab').onclick = () => setMode('timeline');

const timelineY = (time) => timelineTimeScale ? timelineTimeScale.yAt(time) : 0;
const timelineTime = (y) => timelineTimeScale ? timelineTimeScale.timeAt(y) : timelineNow;

const buildTimeline = () => {
  timelineHeight = Math.max(100, timelineScroll.clientHeight - 50);
  timelineScale = timelineHeight / (Number(timelineZoom.value) * 60000);
  timelineTimeScale = createTimeScale(timelineRows, timelineNow, timelineScale);
  const previous = new Map();
  let bottom = timelineHeight;
  for (const row of timelineRows) {
    // Keep dense prompts readable; their printed timestamps retain the exact time.
    row.y = Math.max(timelineY(row.timestamp), previous.get(row.lane) || 0);
    previous.set(row.lane, row.y + 26);
    row.top = timelineY(row.end);
    bottom = Math.max(bottom, row.y + 100);
  }
  timelineCanvas.style.height = `${bottom}px`;
};

const resizeTimeline = () => {
  if (!timelineLoaded || timelineView.hidden) return;
  const anchor = timelineTime(timelineScroll.scrollTop);
  buildTimeline();
  timelineScroll.scrollTop = timelineY(anchor);
  paintTimeline();
};
timelineZoom.onchange = resizeTimeline;
window.sessions.onTimelineZoom((direction) => {
  if (timelineView.hidden) return;
  timelineZoom.selectedIndex = Math.max(0, Math.min(timelineZoom.options.length - 1, timelineZoom.selectedIndex + direction));
  resizeTimeline();
});

const loadTimeline = async () => {
  const request = ++timelineRequest;
  try {
    const data = await window.sessions.timeline();
    if (request !== timelineRequest) return;
    const anchor = timelineLoaded && timelineScroll.scrollTop > 10 ? timelineTime(timelineScroll.scrollTop) : null;
    timelineRows = data.rows;
    timelineUntimed = data.untimed;
    timelineNow = Math.max(Date.now(), ...timelineRows.slice(0, 1).map((row) => row.end));
    buildTimeline();
    timelineLoaded = true;
    if (anchor !== null) timelineScroll.scrollTop = timelineY(anchor);
    paintTimeline();
  } catch {
    timelineStatus.textContent = 'Unable to load timeline. Switch tabs to retry.';
    timelineLoaded = false;
  }
};

const timelineClock = (time) => new Date(time).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
const timelineDate = (time) => new Date(time).toLocaleDateString([], { month: 'short', day: 'numeric' });
const laneColor = (lane) => {
  let hash = 0;
  for (const character of lane) hash = (hash * 31 + character.charCodeAt(0)) | 0;
  return `hsl(${Math.abs(hash) % 360} 55% 66%)`;
};

const paintTimeline = () => {
  if (timelineView.hidden || !timelineLoaded) return;
  const top = timelineScroll.scrollTop;
  const bottom = top + timelineScroll.clientHeight - 50;
  const visible = timelineRows.filter((row) => row.y + 28 >= top && row.top <= bottom);
  const lanes = new Map(visible.map((row) => [row.lane, row]));
  const entering = [...lanes.keys()].filter((lane) => !timelineLanes.includes(lane));
  timelineLanes = [...entering, ...timelineLanes.filter((lane) => lanes.has(lane))];
  const width = Math.max(240, (timelineScroll.clientWidth - 128) / Math.max(1, timelineLanes.length));
  const totalWidth = Math.max(timelineScroll.clientWidth, 128 + width * timelineLanes.length);
  timelineCanvas.style.width = `${totalWidth}px`;
  timelineHead.style.width = `${totalWidth}px`;
  timelineHead.innerHTML = '<div class="timeline-axis-head">TIME ↓</div>';
  const fragment = document.createDocumentFragment();
  const place = (element, x, y, w, h) => {
    Object.assign(element.style, { left: `${x}px`, top: `${y}px`, width: `${w}px` });
    if (h !== undefined) element.style.height = `${h}px`;
    return element;
  };
  timelineLanes.forEach((lane, index) => {
    const row = lanes.get(lane);
    const heading = document.createElement('div');
    heading.className = 'timeline-lane-head';
    heading.textContent = row.label;
    heading.title = `${row.label}\n${row.lane}\n${row.kind}\n${row.cwd || 'No recorded directory'}`;
    heading.style.borderTopColor = laneColor(lane);
    timelineHead.append(place(heading, 128 + index * width, 0, width, 50));
    const column = document.createElement('div');
    column.className = 'timeline-column';
    fragment.append(place(column, 128 + index * width, top, width, bottom - top + 50));
  });
  for (const row of visible) {
    const x = 128 + timelineLanes.indexOf(row.lane) * width;
    if (row.end > row.timestamp) {
      const bar = document.createElement('div');
      bar.className = 'timeline-activity';
      bar.style.background = laneColor(row.lane);
      bar.title = `Inferred activity: ${timelineClock(row.timestamp)}–${timelineClock(row.end)}`;
      const start = Math.max(top, row.top);
      fragment.append(place(bar, x + 5, start, width - 10, Math.min(bottom + 40, row.y + 25) - start));
    }
    if (row.y + 28 < top || row.y > bottom + 40) continue;
    const button = document.createElement('button');
    button.className = 'timeline-prompt';
    button.style.borderLeftColor = laneColor(row.lane);
    button.title = `${new Date(row.timestamp).toLocaleString()} · ${TOOL_NAMES[row.tool]}\n${row.text}\nOpen this message`;
    const time = document.createElement('span');
    time.className = 'timeline-prompt-time';
    time.textContent = timelineClock(row.timestamp);
    button.append(time, document.createTextNode(row.text));
    button.onclick = async () => {
      setMode('sessions');
      const summary = { ...row, id: row.key.slice(row.tool.length + 1) };
      await select(row.key, summary);
      if (selectedKey !== row.key) return;
      const target = detailElement.querySelector(`[data-message-index="${row.messageIndex}"]`);
      if (target) {
        target.open = true;
        target.classList.add('timeline-selected');
        updateTurns();
        const header = detailElement.querySelector('.detail-header');
        detailElement.scrollTop += target.getBoundingClientRect().top - detailElement.getBoundingClientRect().top - header.offsetHeight - 16;
        setTimeout(() => target.classList.remove('timeline-selected'), 2500);
      }
    };
    fragment.append(place(button, x + 8, row.y, width - 16, 25));
  }
  let lastLabel = -Infinity;
  const label = (time, y) => {
    if (y < top - 24 || y > bottom + 40 || y - lastLabel < 42) return;
    lastLabel = y;
    const tick = document.createElement('div');
    tick.className = 'timeline-tick';
    tick.textContent = `${timelineDate(time)} · ${timelineClock(time)}`;
    fragment.append(place(tick, 0, y, totalWidth));
  };
  const tickMinutes = Number(timelineZoom.value) <= 30 ? 5 : Number(timelineZoom.value) <= 120 ? 10 : 30;
  const step = tickMinutes * 60000;
  for (const segment of timelineTimeScale.segments) {
    if (segment.bottom < top || segment.top > bottom + 40) continue;
    if (segment.gap) {
      const marker = document.createElement('div');
      marker.className = 'timeline-gap';
      const minutes = Math.round((segment.newer - segment.older) / 60000);
      const duration = minutes >= 1440 ? `${Math.floor(minutes / 1440)}d ${Math.floor(minutes % 1440 / 60)}h`
        : minutes >= 60 ? `${Math.floor(minutes / 60)}h ${minutes % 60}m` : `${minutes}m`;
      marker.textContent = `↯ ${duration} skipped`;
      marker.title = `${new Date(segment.newer).toLocaleString()} → ${new Date(segment.older).toLocaleString()}\nNo recorded messages or inferred activity`;
      fragment.append(place(marker, timelineScroll.scrollLeft, segment.top, 128, 44));
      const rule = document.createElement('div');
      rule.className = 'timeline-gap-rule';
      fragment.append(place(rule, 128, segment.top + 22, totalWidth - 128));
      lastLabel = segment.bottom;
      continue;
    }
    const first = Math.min(segment.newer, timelineTime(top));
    for (let time = Math.floor(first / step) * step; time >= segment.older && timelineY(time) <= bottom + 40; time -= step) {
      label(time, timelineY(time));
    }
  }
  timelineCanvas.replaceChildren(fragment);
  timelineStatus.textContent = `${timelineLanes.length} columns in view · ${timelineRows.length.toLocaleString()} prompts${timelineUntimed ? ` · ${timelineUntimed.toLocaleString()} without timestamps omitted` : ''}`;
  if (!timelineRows.length) timelineCanvas.textContent = 'No timestamped prompts yet. The timeline updates when indexing finishes.';
};

const queueTimeline = () => {
  if (timelineFrame !== null) return;
  timelineFrame = requestAnimationFrame(() => { timelineFrame = null; paintTimeline(); });
};
timelineScroll.addEventListener('scroll', queueTimeline);
new ResizeObserver(() => {
  if (timelineScroll.clientHeight - 50 !== timelineHeight) resizeTimeline();
  else queueTimeline();
}).observe(timelineScroll);
const probe = document.getElementById('timeline-probe');
timelineScroll.addEventListener('mousemove', (event) => {
  if (!timelineLoaded || !timelineRows.length) return;
  const y = event.clientY - timelineCanvas.getBoundingClientRect().top;
  const time = timelineTime(y);
  const active = new Set(timelineRows.filter((row) => row.timestamp <= time && row.end >= time).map((row) => row.lane));
  probe.hidden = false;
  probe.textContent = `${timelineDate(time)} ${timelineClock(time)} · ${active.size} inferred active`;
  probe.style.top = `${event.clientY - timelineScroll.getBoundingClientRect().top + timelineScroll.scrollTop + 16}px`;
  probe.style.left = `${timelineScroll.scrollLeft + 12}px`;
});
timelineScroll.addEventListener('mouseleave', () => { probe.hidden = true; });
document.getElementById('timeline-now').onclick = () => { timelineScroll.scrollTop = 0; loadTimeline(); };
document.getElementById('timeline-date').onchange = (event) => {
  const date = new Date(`${event.target.value}T23:59:59`);
  if (Number.isFinite(date.getTime())) timelineScroll.scrollTop = timelineY(Math.min(timelineNow, date.getTime()));
};
document.addEventListener('sessions-loaded', () => { if (timelineLoaded || !timelineView.hidden) loadTimeline(); });
window.sessions.onSessions(() => { if (timelineLoaded || !timelineView.hidden) loadTimeline(); });
setInterval(() => { if (!timelineView.hidden && timelineLoaded && timelineScroll.scrollTop < 10) loadTimeline(); }, 60000);
