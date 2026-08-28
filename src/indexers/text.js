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

const firstPrompt = (messages) => {
  const prompt = messages.find((message) => message.role === 'user' && message.text.length > 2);
  return prompt ? collapse(prompt.text).slice(0, 120) : '';
};

module.exports = { extractContent, buildSearchText, firstPrompt, collapse };
