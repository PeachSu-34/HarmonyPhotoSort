export function fitsWallpaper(width: number, height: number, textLength: number): boolean {
  return fitsWallpaperSize(width, height) && textLength <= 13;
}

export function fitsWallpaperSize(width: number, height: number): boolean {
  const ratio = width / height;
  const phone = width >= 540 && height >= 960 && ratio >= 0.40 && ratio <= 0.80;
  const desktop = width >= 1280 && height >= 720 &&
    ((ratio >= 1.24 && ratio <= 2.45) || (width >= 2800 && ratio >= 3.40 && ratio <= 3.65));
  return phone || desktop;
}

export function wallpaperThreshold(width: number, height: number): number {
  const ratio = Math.max(width, height) / Math.min(width, height);
  const standard = Math.max(width, height) >= 1080 &&
    (Math.abs(ratio - 1.78) <= 0.07 || Math.abs(ratio - 2.17) <= 0.12 || Math.abs(ratio - 2.37) <= 0.06 ||
      (width > height && (Math.abs(ratio - 1.60) <= 0.06 || Math.abs(ratio - 3.56) <= 0.12)));
  return standard ? ANIME_THRESHOLD - 0.06 : ANIME_THRESHOLD;
}

export function captionLength(text: string): number {
  const watermark = /^(?:@[\w.-]+|https?:\/\/\S+|www\.\S+|(?:pixiv|微博|小红书|bilibili)\s*[:：#@]?\s*[\w.-]+)$/i;
  return text.split(/\r?\n/).filter(line => !watermark.test(line.trim())).join('').replace(/\s/g, '').length;
}

export function isAnimeArtwork(scores: Float32Array): boolean {
  return animeArtworkScore(scores) >= ANIME_THRESHOLD;
}

export const ANIME_THRESHOLD: number = 0.42;

function bestAnime(scores: Float32Array): number {
  return Math.max(scores[0], scores[1], scores[2], scores[7], scores[8], scores[9], scores[19],
    scores[21], scores[22], scores[23]);
}

export function animeArtworkScore(scores: Float32Array): number {
  if (scores.length !== 30 || scores.some(value => !Number.isFinite(value))) {
    throw new Error('动漫模型输出不正确');
  }
  // Use the strongest anime description so extra prompts do not inflate its score.
  const anime = bestAnime(scores);
  const best = Math.max(anime, scores[3], scores[4], scores[5], scores[6], scores[15]);
  const animeWeight = Math.exp(anime - best);
  let total = animeWeight;
  for (let index = 3; index < 7; index++) {
    total += Math.exp(scores[index] - best);
  }
  return animeWeight / (total + Math.exp(scores[15] - best));
}

export function hasSoftEdges(rgba: Uint8Array, side: number): boolean {
  let variation = 0;
  let curvature = 0;
  const row = side * 4;
  // Compare changes in luminance at the existing inference resolution. This is a supporting cue only.
  for (let y = 1; y < side - 1; y += 2) {
    for (let x = 1; x < side - 1; x += 2) {
      const offset = (y * side + x) * 4;
      const center = luminance(rgba, offset);
      const left = luminance(rgba, offset - 4) - center;
      const right = luminance(rgba, offset + 4) - center;
      const top = luminance(rgba, offset - row) - center;
      const bottom = luminance(rgba, offset + row) - center;
      variation += Math.abs(left) + Math.abs(right) + Math.abs(top) + Math.abs(bottom);
      curvature += Math.abs(left + right) + Math.abs(top + bottom);
    }
  }
  return variation > 0 && curvature / variation < 0.42;
}

function luminance(rgba: Uint8Array, offset: number): number {
  return rgba[offset] * 0.2126 + rgba[offset + 1] * 0.7152 + rgba[offset + 2] * 0.0722;
}

export function looksLikeReaction(scores: Float32Array, textLength: number, wallpaperSize: boolean,
  softEdges: boolean, compact: boolean = false): boolean {
  const anime = bestAnime(scores);
  const other = Math.max(scores[3], scores[4], scores[5], scores[6], scores[15]);
  const explicitReaction = Math.max(scores[10], scores[11], scores[13], scores[14], scores[20]);
  if (explicitReaction >= Math.max(anime, other) + (compact && !wallpaperSize ? 0.45 : 0.8)) {
    return true;
  }
  const reaction = Math.max(explicitReaction, scores[12]);
  const hasCaption = textLength >= (wallpaperSize ? 4 : 3);
  const tolerance = wallpaperSize ? 0.85 : 2.0;
  const margin = wallpaperSize ? 1.25 : 1.05;
  return anime >= other + margin && reaction >= other + 0.8 &&
    ((hasCaption && reaction >= anime - tolerance) || (!wallpaperSize && softEdges && reaction >= anime - 2.4));
}

export function hasReactionEvidence(scores: Float32Array): boolean {
  const reaction = Math.max(scores[10], scores[11], scores[12], scores[13], scores[14], scores[20],
    scores[24], scores[25], scores[26], scores[27], scores[28], scores[29]);
  const other = Math.max(scores[3], scores[4], scores[5], scores[6], scores[15], scores[17], scores[18]);
  return reaction >= other - 0.25;
}

export function looksLikeSceneMeme(scores: Float32Array, textLength: number, wallpaperSize: boolean,
  compact: boolean): boolean {
  const document = Math.max(scores[5], scores[6], scores[17], scores[18]);
  const ordinaryScene = Math.max(scores[3], scores[4], scores[15], document);
  if (textLength >= 18 && Math.max(scores[27], scores[28]) >= ordinaryScene + 1.35) {
    return true;
  }
  if (textLength >= 12 && textLength <= 65 && Math.min(scores[10], scores[24], scores[28]) >= document + 2.4 &&
    scores[28] >= scores[15] - 1.8 && scores[28] >= bestAnime(scores) + 1.8) {
    return true;
  }
  if (wallpaperSize) {
    return false;
  }
  if (compact && scores[25] >= ordinaryScene + 1.6) {
    return true;
  }
  if (textLength >= 4 && textLength <= 85) {
    const caption = Math.max(scores[24], scores[26], scores[28]);
    if (caption >= Math.max(scores[3], scores[4], document) + 1.1 && caption >= scores[15] - 0.35) {
      return true;
    }
    const subtitledScene = textLength >= 6 && textLength <= 60 && scores[15] >= document + 0.65 &&
      caption >= document + 0.5;
    return subtitledScene || (compact && scores[29] >= document + 1.1 && scores[29] >= scores[15] - 2.8);
  }
  return textLength <= 3 && scores[29] >= ordinaryScene + 0.85 && scores[24] >= ordinaryScene + 0.85;
}

export function looksLikeSquareSticker(scores: Float32Array, rgba: Uint8Array, side: number): boolean {
  const anime = bestAnime(scores);
  const other = Math.max(scores[3], scores[4], scores[5], scores[6], scores[15], scores[17], scores[18]);
  if (scores[12] < anime - 1.0 || scores[12] < other + 3.0 || scores[12] < scores[27] + 0.9) {
    return false;
  }
  let matchingCorners = 0;
  const near = Math.max(1, Math.floor(side * 0.04));
  const far = side - 1 - near;
  for (const corner of [(near * side + near) * 4, (near * side + far) * 4,
    (far * side + near) * 4, (far * side + far) * 4]) {
    if (Math.max(rgba[corner], rgba[corner + 1], rgba[corner + 2]) <= 24 || rgba[corner + 3] <= 16) {
      matchingCorners++;
    }
  }
  return matchingCorners === 4;
}

export function looksLikeAnimeCollage(scores: Float32Array, textLength: number): boolean {
  const illustration = Math.max(scores[0], scores[1], scores[21]);
  return textLength >= 14 && textLength <= 55 && animeArtworkScore(scores) >= 0.86 &&
    illustration >= scores[8] - 1.65 && illustration >= Math.max(scores[11], scores[14]) + 2.0 &&
    illustration >= scores[27] + 1.0 && scores[8] >= scores[3] + 2.0 && scores[7] >= scores[5] + 3.0;
}

export function looksLikeHandwrittenNotes(scores: Float32Array): boolean {
  const competing = Math.max(bestAnime(scores), scores[3], scores[4], scores[5], scores[6], scores[15],
    scores[17], scores[18]);
  return scores[16] - competing >= 1.1;
}
