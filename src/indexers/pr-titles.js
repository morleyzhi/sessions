const PR_URL = /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/\d+/;

// Read saved GitHub responses and named links without fetching the PR.
const collectPRTitles = (value, titles, depth = 0) => {
  if (!value || depth > 12) return;
  if (typeof value === 'object') {
    const url = typeof value.url === 'string' && value.url.match(PR_URL)?.[0];
    if (typeof value.title === 'string' && value.title.trim()) {
      if (url) titles[url] = value.title.trim();
      else if (Number.isInteger(value.number)) titles[`#${value.number}`] = value.title.trim();
    }
    for (const child of Object.values(value)) collectPRTitles(child, titles, depth + 1);
  } else if (typeof value === 'string' && (value.includes('github.com/') || (value.includes('"title"') && value.includes('"number"')))) {
    for (const match of value.matchAll(/https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/pull\/\d+/g)) titles[`repo:${match[1]}`] = '';
    for (const match of value.matchAll(/\[([^\]\n]+)\]\((https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/\d+)[^\s)]*\)/g)) {
      const label = match[1].replace(/[*`]/g, '').trim();
      if (!/^(?:(?:draft\s+)?(?:pr|pull request)\s*)?#?\d+$/i.test(label) && !/^https?:/.test(label) && !/^(?:here|link|pr|pull request|draft pr|view pr)$/i.test(label)) {
        titles[match[2]] ||= label;
      }
    }
    const first = value.search(/[\[{]/);
    const last = Math.max(value.lastIndexOf('}'), value.lastIndexOf(']'));
    if (first !== -1 && last > first) {
      try { collectPRTitles(JSON.parse(value.slice(first, last + 1)), titles, depth + 1); } catch { /* Plain transcript text. */ }
    }
  }
};

const resolvePRTitles = (titles) => {
  const repositories = Object.keys(titles).filter((key) => key.startsWith('repo:'));
  const result = {};
  for (const [key, title] of Object.entries(titles)) {
    if (key.startsWith('https:')) result[key] = title;
    else if (key.startsWith('#') && repositories.length === 1) {
      result[`https://github.com/${repositories[0].slice(5)}/pull/${key.slice(1)}`] = title;
    }
  }
  return result;
};

module.exports = { collectPRTitles, resolvePRTitles };
