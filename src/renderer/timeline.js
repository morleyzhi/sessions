const timelineView = document.getElementById('timeline-view');
const timelineScroll = document.getElementById('timeline-scroll');
const timelineCanvas = document.getElementById('timeline-canvas');
const timelineHead = document.getElementById('timeline-head');
const timelineStatus = document.getElementById('timeline-status');
let timelineRows = [];
let timelinePoints = [];
let timelineGaps = [];
let timelineLanes = [];
let timelineNow = Date.now();
let timelineLoaded = false;
let timelineRequest = 0;
let timelineFrame = null;
let timelineUntimed = 0;

const setMode = (mode) => {
  const timeline = mode === 'timeline';
  document.getElementById('sessions-view').hidden = timeline;
  timelineView.hidden = !timeline;
  document.getElementById('sessions-tab').setAttribute('aria-pressed', String(!timeline));
  document.getElementById('timeline-tab').setAttribute('aria-pressed', String(timeline));
  if (timeline) {
    if (!timelineLoaded) loadTimeline();
    else paintTimeline();
  }
};

document.getElementById('sessions-tab').onclick = () => setMode('sessions');
document.getElementById('timeline-tab').onclick = () => setMode('timeline');

// Locate the two recorded times surrounding a scroll position or timestamp.
const timelineIndex = (value, field, descending = false) => {
  let low = 0;
  let high = timelinePoints.length - 1;
  while (low < high) {
    const middle = Math.ceil((low + high) / 2);
    if (descending ? timelinePoints[middle][field] >= value : timelinePoints[middle][field] <= value) low = middle;
    else high = middle - 1;
  }
  return low;
};

const timelineY = (time) => {
  if (!timelinePoints.length) return 0;
  const index = timelineIndex(time, 'time', true);
  const point = timelinePoints[index];
  const next = timelinePoints[index + 1];
  return next ? point.y + (point.time - time) / (point.time - next.time) * (next.y - point.y) : point.y;
};

const timelineTime = (y) => {
  if (!timelinePoints.length) return timelineNow;
  const index = timelineIndex(y, 'y');
  const point = timelinePoints[index];
  const next = timelinePoints[index + 1];
  return next ? point.time - (y - point.y) / (next.y - point.y) * (point.time - next.time) : point.time;
};

const buildTimeline = () => {
  const times = new Set([timelineNow]);
  const counts = new Map();
  for (const row of timelineRows) {
    times.add(row.timestamp);
    times.add(row.end);
    const key = `${row.timestamp}:${row.lane}`;
    row.offset = (counts.get(key) || 0) * 28;
    counts.set(key, row.offset / 28 + 1);
  }
  const heights = new Map();
  for (const row of timelineRows) heights.set(row.timestamp, Math.max(heights.get(row.timestamp) || 0, row.offset + 28));
  const sorted = [...times].sort((a, b) => b - a);
  timelineGaps = [];
  timelinePoints = [];
  let y = 16;
  sorted.forEach((time, index) => {
    if (index) {
      const previous = sorted[index - 1];
      const delta = previous - time;
      const height = Math.max(heights.get(previous) || 28, delta > 10 * 60000 ? 76 : delta / 60000 * 64);
      if (delta > 10 * 60000) timelineGaps.push({ y: y + height / 2, duration: delta });
      y += height;
    }
    timelinePoints.push({ time, y });
  });
  for (const row of timelineRows) {
    row.y = timelineY(row.timestamp) + row.offset;
    row.top = timelineY(row.end);
  }
  timelineCanvas.style.height = `${y + 100}px`;
};

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
    heading.title = `${row.kind}\n${row.cwd || 'No recorded directory'}`;
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
  for (let index = timelineIndex(Math.max(0, top - 64), 'y'); index < timelinePoints.length; index++) {
    const point = timelinePoints[index];
    const next = timelinePoints[index + 1];
    if (point.y > bottom + 40) break;
    label(point.time, point.y);
    if (next && point.time - next.time <= 10 * 60000) {
      for (let time = Math.floor(point.time / 60000) * 60000; time > next.time; time -= 60000) label(time, timelineY(time));
    }
  }
  for (const gap of timelineGaps) {
    if (gap.y < top || gap.y > bottom) continue;
    const element = document.createElement('div');
    element.className = 'timeline-gap';
    const minutes = Math.round(gap.duration / 60000);
    element.textContent = `${minutes >= 1440 ? `${(minutes / 1440).toFixed(1)}d` : minutes >= 60 ? `${(minutes / 60).toFixed(1)}h` : `${minutes}m`} between recorded events`;
    fragment.append(place(element, 128, gap.y, totalWidth - 128, 24));
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
new ResizeObserver(queueTimeline).observe(timelineScroll);
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
