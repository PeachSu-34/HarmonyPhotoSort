const START_TOKEN = 101;
const END_TOKEN = 102;
const UNKNOWN_TOKEN = 100;
const TOKEN_LIMIT = 192;
const UNDECIDED = '待确认';

function isChineseCharacter(point: number): boolean {
  return (point >= 0x4e00 && point <= 0x9fff) || (point >= 0x3400 && point <= 0x4dbf) ||
    (point >= 0x20000 && point <= 0x2a6df) || (point >= 0x2a700 && point <= 0x2b73f) ||
    (point >= 0x2b740 && point <= 0x2b81f) || (point >= 0x2b820 && point <= 0x2ceaf) ||
    (point >= 0xf900 && point <= 0xfaff) || (point >= 0x2f800 && point <= 0x2fa1f);
}

function isPunctuation(character: string, point: number): boolean {
  return (point >= 33 && point <= 47) || (point >= 58 && point <= 64) || (point >= 91 && point <= 96) ||
    (point >= 123 && point <= 126) || /\p{P}/u.test(character);
}

function tokenizeWord(word: string, vocabulary: Map<string, number>): number[] {
  const whole = vocabulary.get(word);
  if (whole !== undefined) {
    return [whole];
  }
  const characters = Array.from(word);
  if (characters.length > 100) {
    return [UNKNOWN_TOKEN];
  }
  const tokens: number[] = [];
  let offset = 0;
  while (offset < characters.length) {
    let end = characters.length;
    let token: number | undefined;
    while (end > offset) {
      const piece = (offset === 0 ? '' : '##') + characters.slice(offset, end).join('');
      token = vocabulary.get(piece);
      if (token !== undefined) {
        break;
      }
      end--;
    }
    if (token === undefined) {
      return [UNKNOWN_TOKEN];
    }
    tokens.push(token);
    offset = end;
  }
  return tokens;
}

export function encodeEmbeddingText(text: string, vocabulary: Map<string, number>): number[] {
  return encodeEmbeddingPassages(text, vocabulary, 1)[0];
}

export function encodeEmbeddingPassages(text: string, vocabulary: Map<string, number>, limit: number = 3): number[][] {
  const spatial: string[] = [];
  for (const character of text.slice(0, 6000)) {
    const point = character.codePointAt(0) ?? 0;
    if (/\s/u.test(character)) {
      spatial.push(' ');
    } else if (point !== 0xfffd && !/[\p{Cc}\p{Cf}]/u.test(character)) {
      if (isChineseCharacter(point) || isPunctuation(character, point)) {
        spatial.push(' ', character, ' ');
      } else {
        spatial.push(character);
      }
    }
  }
  const passages: number[][] = [];
  let tokens: number[] = [START_TOKEN];
  for (const word of spatial.join('').split(/ +/)) {
    if (word.length === 0) {
      continue;
    }
    for (const token of tokenizeWord(word, vocabulary)) {
      if (tokens.length === TOKEN_LIMIT - 1) {
        tokens.push(END_TOKEN);
        passages.push(tokens);
        if (passages.length === limit) {
          return passages;
        }
        tokens = [START_TOKEN];
      }
      tokens.push(token);
    }
  }
  tokens.push(END_TOKEN);
  passages.push(tokens);
  return passages;
}

export function selectSemanticCategory(scores: Map<string, number>, allowStructuredText: boolean = false): string {
  let topCategory = UNDECIDED;
  let best = -1;
  let second = -1;
  for (const entry of scores) {
    const category = entry[0];
    const score = entry[1];
    if (!Number.isFinite(score)) {
      continue;
    }
    if (score > best) {
      second = best;
      best = score;
      topCategory = category;
    } else if (score > second) {
      second = score;
    }
  }
  const structured = allowStructuredText && (topCategory === '信息' || topCategory === '知识');
  return best >= (structured ? 0.50 : 0.52) && best - second >= (structured ? 0.035 : 0.045) ? topCategory : UNDECIDED;
}
