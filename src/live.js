const path = require('path');
const { execFileSync } = require('child_process');

// The CLI each tool's sessions belong to, by process name.
const CLI_NAMES = { claude: 'claude', codex: 'codex', 'cursor-agent': 'cursor' };

// Background helpers that share a CLI's name but never own a session.
const HELPER_ARGS = /--type=|app-server|code-mode-host|\bsandbox\b|\bmcp\b|Frameworks\//;

const PS_LINE = /^\s*(\d+)\s+(\w{3} \w{3}\s+\d+ \d+:\d+:\d+ \d{4})\s+(.*)$/;

// A resumed session names its id on the command line.
const SESSION_ID = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i;

const run = (command, args) => {
  try {
    return execFileSync(command, args, { encoding: 'utf8', timeout: 4000 });
  } catch {
    return '';
  }
};

// Every running CLI process, as { pid, tool, startedAt }.
const cliProcesses = () => {
  const processes = [];
  for (const line of run('ps', ['-axo', 'pid=,lstart=,args=']).split('\n')) {
    const match = PS_LINE.exec(line);
    if (!match) continue;
    const [, pid, started, args] = match;
    const tool = CLI_NAMES[path.basename(args.split(' ')[0])];
    if (!tool || HELPER_ARGS.test(args)) continue;
    processes.push({
      pid,
      tool,
      startedAt: new Date(started).getTime(),
      sessionId: (SESSION_ID.exec(args) || [''])[0].toLowerCase(),
    });
  }
  return processes;
};

// Working directory of each pid, keyed by pid.
const workingDirectories = (pids) => {
  const directories = new Map();
  if (!pids.length) return directories;
  let pid = '';
  for (const line of run('lsof', ['-a', '-d', 'cwd', '-Fpn', '-p', pids.join(',')]).split('\n')) {
    if (line.startsWith('p')) pid = line.slice(1);
    else if (line.startsWith('n')) directories.set(pid, line.slice(1));
  }
  return directories;
};

/**
 * Keys of the sessions a running CLI currently owns. A session counts as live
 * when a CLI resumed it by id, or when a CLI for its tool is running in its
 * working directory and the session was written to after that process started —
 * so the newest session in a directory is marked, not every past session there.
 */
const liveSessionKeys = (summaries) => {
  const processes = cliProcesses();
  const directories = workingDirectories(processes.map((process) => process.pid));
  const live = new Set();

  for (const { pid, tool, startedAt, sessionId } of processes) {
    if (sessionId) {
      live.add(`${tool}:${sessionId}`);
      continue;
    }
    const cwd = directories.get(pid);
    if (!cwd) continue;
    const owned = summaries
      .filter((summary) => summary.tool === tool && summary.cwd === cwd && summary.updatedAt >= startedAt)
      .sort((a, b) => b.updatedAt - a.updatedAt)[0];
    if (owned) live.add(`${owned.tool}:${owned.id}`);
  }
  return live;
};

module.exports = { liveSessionKeys };
