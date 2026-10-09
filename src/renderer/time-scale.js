// Keep recorded activity at the selected zoom; shorten idle periods over 15 minutes.
const createTimeScale = (rows, now, pixelsPerMs) => {
  const minute = 60000;
  const intervals = rows.map((row) => [row.timestamp, Math.max(row.timestamp, row.end)])
    .sort((a, b) => a[0] - b[0]);
  const merged = [];
  for (const interval of intervals) {
    const last = merged.at(-1);
    if (last && interval[0] <= last[1]) last[1] = Math.max(last[1], interval[1]);
    else merged.push([...interval]);
  }
  const gaps = [];
  let newer = now;
  for (const [start, end] of merged.reverse()) {
    if (newer - end > 15 * minute) gaps.push({ newer: newer - minute, older: end + minute });
    newer = start;
  }
  const segments = [];
  let time = now;
  let y = 0;
  const add = (older, height, gap = false) => {
    if (time <= older) return;
    segments.push({ newer: time, older, top: y, bottom: y + height, gap });
    time = older;
    y += height;
  };
  for (const gap of gaps) {
    add(gap.newer, (time - gap.newer) * pixelsPerMs);
    add(gap.older, 44, true);
  }
  add((merged.at(-1)?.[0] ?? now) - minute * 10, (time - (merged.at(-1)?.[0] ?? now) + minute * 10) * pixelsPerMs);
  const find = (value, field, descending) => {
    let low = 0;
    let high = segments.length - 1;
    while (low < high) {
      const middle = Math.ceil((low + high) / 2);
      if (descending ? segments[middle][field] >= value : segments[middle][field] <= value) low = middle;
      else high = middle - 1;
    }
    return segments[low];
  };
  return {
    segments,
    yAt: (timestamp) => {
      const segment = find(timestamp, 'newer', true);
      return Math.max(0, segment.top + (segment.newer - timestamp) / (segment.newer - segment.older) * (segment.bottom - segment.top));
    },
    timeAt: (position) => {
      const segment = find(position, 'top', false);
      return segment.newer - (position - segment.top) / (segment.bottom - segment.top) * (segment.newer - segment.older);
    },
  };
};

if (typeof module !== 'undefined') module.exports = { createTimeScale };
