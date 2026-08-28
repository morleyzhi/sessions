const MAX_TEXT_PER_SESSION = 40_000;

const collapse = (value) => String(value).replace(/\s+/g, ' ').trim();

const extractContent = (content) => {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content
    .map((part) => {
      if (typeof part === 'string') return part;
      if (!part || typeof part !== 'object') return '';
      if (part.type === 'text' || part.type === 'input_text' || part.type === 'output_text') return part.text || '';
      if (part.type === 'thinking') return part.thinking || '';
      if (part.type === 'tool_use') return `[tool: ${part.name || 'unknown'}]`;
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
const TOOL_MARKER = /^\[tool(?::[^\]]*)?\]$|^\[tool result\]$/;

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

module.exports = { extractContent, buildSearchText, firstPrompt, lastMessageTime, collapse };
