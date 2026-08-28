const readVarint = (buffer, position) => {
  let result = 0n;
  let shift = 0n;
  let cursor = position;
  while (cursor < buffer.length) {
    const byte = buffer[cursor++];
    result |= BigInt(byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) return [result, cursor];
    shift += 7n;
    if (shift > 63n) return [null, cursor];
  }
  return [null, cursor];
};

const looksLikeText = (buffer) => {
  if (buffer.length < 2) return false;
  const text = buffer.toString('utf8');
  if (text.includes('�')) return false;
  const characters = [...text];
  let printable = 0;
  for (const character of characters) {
    const code = character.codePointAt(0);
    if (code === 9 || code === 10 || code === 13 || code >= 32) printable++;
  }
  return printable / characters.length > 0.95;
};

const MAX_DEPTH = 8;

const collectStrings = (buffer, depth, output) => {
  let position = 0;
  while (position < buffer.length) {
    const [tag, afterTag] = readVarint(buffer, position);
    if (tag === null) return output;
    position = afterTag;
    const wireType = Number(tag & 7n);
    if (wireType === 0) {
      const [, afterValue] = readVarint(buffer, position);
      position = afterValue;
    } else if (wireType === 1) {
      position += 8;
    } else if (wireType === 5) {
      position += 4;
    } else if (wireType === 2) {
      const [length, afterLength] = readVarint(buffer, position);
      if (length === null) return output;
      position = afterLength;
      const end = position + Number(length);
      if (end > buffer.length) return output;
      const chunk = buffer.subarray(position, end);
      if (looksLikeText(chunk)) output.push(chunk.toString('utf8'));
      else if (depth < MAX_DEPTH) collectStrings(chunk, depth + 1, output);
      position = end;
    } else {
      return output;
    }
  }
  return output;
};

module.exports = { collectStrings };
