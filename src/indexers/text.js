const MAX_TEXT_PER_SESSION = 40_000;

const collapse = (value) => String(value).replace(/\s+/g, ' ').trim();

// Tool calls that say nothing about what happened, so the transcript hides them.
const BORING_TOOLS = new Set(['TodoWrite', 'todowrite', 'update_plan']);

// The one field of a tool call worth reading: the command, the file, the query.
const SUMMARY_FIELDS = [
  'command',
  'file_path',
  'path',
  'pattern',
  'query',
  'url',
  'description',
  'prompt',
  'notebook_path',
];

const toolSummary = (input) => {
  if (typeof input === 'string') return collapse(input).slice(0, 120);
  if (!input || typeof input !== 'object') return '';
  for (const field of SUMMARY_FIELDS) {
    if (typeof input[field] === 'string' && input[field].trim()) {
      return collapse(input[field]).slice(0, 120);
    }
  }
  return '';
};

const toolMarker = (name, input) => {
  const summary = toolSummary(input);
  return summary ? `[tool: ${name}] ${summary}` : `[tool: ${name}]`;
};

const extractContent = (content) => {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content
    .map((part) => {
      if (typeof part === 'string') return part;
      if (!part || typeof part !== 'object') return '';
      if (part.type === 'text' || part.type === 'input_text' || part.type === 'output_text') return part.text || '';
      if (part.type === 'thinking') return part.thinking || '';
      if (part.type === 'tool_use') return toolMarker(part.name || 'unknown', part.input);
      if (part.type === 'tool_result') return '[tool result]';
      return '';
    })
    .filter(Boolean)
    .join('\n');
};

const buildSearchText = (messages) => {
  let text = '';
  for (const message of messages) {
    if (text.length >= MAX_TEXT_PER_SESSION) break;
    text += `${message.text}\n`;
  }
  return text.slice(0, MAX_TEXT_PER_SESSION);
};

// A turn someone actually wrote, as opposed to a tool call or its result.
const TOOL_MARKER = /^\[tool\b[^\]]*\]/;

const isToolOnly = (text) => text.split('\n').every((line) => TOOL_MARKER.test(line.trim()));

/**
 * When the session last had something written to it: the moment the assistant
 * finished its reply, or the moment you sent yours. Tool calls and their
 * results keep streaming in long after either, so they do not count.
 */
const lastMessageTime = (messages) => {
  for (let index = messages.length - 1; index >= 0; index--) {
    const message = messages[index];
    if (message.timestamp && !isToolOnly(message.text)) return message.timestamp;
  }
  return null;
};

const firstPrompt = (messages) => {
  const prompt = messages.find((message) => message.role === 'user' && message.text.length > 2);
  return prompt ? collapse(prompt.text).slice(0, 120) : '';
};

// What a tool-only turn did, one line per call. Results and bookkeeping drop out.
const toolCalls = (text) =>
  text
    .split('\n')
    .map((line) => line.trim().match(/^\[tool: ([^\]]*)\]\s*(.*)$/))
    .filter(Boolean)
    .map((match) => ({ name: match[1], summary: match[2] }))
    .filter((call) => !BORING_TOOLS.has(call.name));

module.exports = {
  extractContent,
  buildSearchText,
  firstPrompt,
  lastMessageTime,
  collapse,
  isToolOnly,
  toolCalls,
  toolMarker,
};
