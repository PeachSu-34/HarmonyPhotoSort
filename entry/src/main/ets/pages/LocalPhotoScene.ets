import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { CategoryRule, looksLikeFormulaStrip, REVIEW_CATEGORY, wallpaperCategory } from './CategoryRules';
import { LocalAnimeWallpaper } from './LocalAnimeWallpaper';
import {
  animeArtworkScore, ANIME_THRESHOLD, captionLength, fitsWallpaper, fitsWallpaperSize, hasReactionEvidence, hasSoftEdges,
  looksLikeAnimeCollage, looksLikeHandwrittenNotes, looksLikeReaction, looksLikeSceneMeme, looksLikeSquareSticker,
  wallpaperThreshold
} from './WallpaperRules';

const MODEL_RESOURCE = 'photosort_model/mobilenetv2.ms';
const MODEL_SIZE = 224;
const LABEL_COUNT = 1001;
// ImageNet indexes for alp, cliff, coral reef, geyser, lakeside, promontory, sandbar, seashore, valley and volcano.
const LANDSCAPE_LABELS = new Set<number>([971, 973, 974, 975, 976, 977, 978, 979, 980, 981]);

async function readFullFrame(source: image.ImageSource, size: image.Size): Promise<Uint8Array> {
  const scale = MODEL_SIZE / Math.max(size.width, size.height);
  const frame = await source.createPixelMap({
    desiredSize: { width: Math.max(1, Math.round(size.width * scale)), height: Math.max(1, Math.round(size.height * scale)) },
    desiredPixelFormat: image.PixelMapFormat.RGBA_8888
  });
  try {
    const frameSize = (await frame.getImageInfo()).size;
    if (frameSize.width > MODEL_SIZE || frameSize.height > MODEL_SIZE) {
      throw new Error('全图复判尺寸不正确');
    }
    const data = new Uint8Array(frame.getPixelBytesNumber());
    await frame.readPixelsToBuffer(data.buffer);
    const stride = frame.getBytesNumberPerRow();
    const rgba = new Uint8Array(MODEL_SIZE * MODEL_SIZE * 4);
    rgba.fill(122);
    const x = Math.floor((MODEL_SIZE - frameSize.width) / 2);
    const y = Math.floor((MODEL_SIZE - frameSize.height) / 2);
    for (let row = 0; row < frameSize.height; row++) {
      const start = row * stride;
      rgba.set(data.subarray(start, start + frameSize.width * 4), ((y + row) * MODEL_SIZE + x) * 4);
    }
    return rgba;
  } finally {
    await frame.release();
  }
}

export class SceneMatch {
  readonly category: string;
  readonly hint: string;

  constructor(category: string, hint: string = '') {
    this.category = category;
    this.hint = hint;
  }
}

export class LocalPhotoScene {
  private loadingModel?: Promise<mindSporeLite.Model>;
  private readonly landscape: boolean;
  private readonly animeCategory: string;
  private readonly naturalWallpaperCategory: string;
  private readonly reactionCategory: string;
  private readonly knowledge: boolean;
  private readonly anime = new LocalAnimeWallpaper();
  private animeUnavailable: boolean = false;

  constructor(rules: CategoryRule[]) {
    this.landscape = rules.some(rule => rule.useDefaults && rule.description.length === 0 && rule.name === '风景');
    this.animeCategory = wallpaperCategory(rules, true);
    this.naturalWallpaperCategory = wallpaperCategory(rules, false);
    this.reactionCategory = rules.find(rule => rule.useDefaults && /^(表情包|聊天表情|梗图)$/.test(rule.name))?.name ?? '';
    this.knowledge = rules.some(rule => rule.useDefaults && rule.name === '知识');
  }

  shouldAnalyze(textLength: number): boolean {
    return (this.knowledge && textLength <= 160) || (this.reactionCategory.length > 0 && textLength <= 260) ||
      (this.landscape && textLength <= 45) || (this.animeCategory.length > 0 && textLength <= 55);
  }

  async classify(context: common.UIAbilityContext, uri: string, text: string, screenshot: boolean): Promise<SceneMatch> {
    const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    let source: image.ImageSource | undefined;
    let pixels: image.PixelMap | undefined;
    try {
      source = image.createImageSource(file.fd);
      const size = (await source.getImageInfo()).size;
      const textLength = captionLength(text);
      if (this.knowledge && size.height <= 200 && size.width / size.height >= 3.8 && looksLikeFormulaStrip(text)) {
        return new SceneMatch('知识', '检测到裁切后的数学公式');
      }
      const wallpaperSize = !screenshot && fitsWallpaperSize(size.width, size.height);
      const fits = wallpaperSize && this.animeCategory.length > 0 && fitsWallpaper(size.width, size.height, textLength);
      const collage = wallpaperSize && this.animeCategory.length > 0 && size.width < size.height &&
        textLength >= 14 && textLength <= 55;
      const tryReaction = this.reactionCategory.length > 0 || (this.animeCategory.length > 0 && wallpaperSize);
      if (!fits && !tryReaction && !this.landscape && !this.knowledge) {
        return new SceneMatch(REVIEW_CATEGORY, screenshot ? '截图不归入壁纸' : this.wallpaperHint(size.width, size.height, 0, false));
      }
      const edge = Math.min(size.width, size.height);
      pixels = await source.createPixelMap({
        desiredSize: { width: MODEL_SIZE, height: MODEL_SIZE },
        desiredRegion: {
          x: Math.floor((size.width - edge) / 2), y: Math.floor((size.height - edge) / 2),
          size: { width: edge, height: edge }
        },
        cropAndScaleStrategy: image.CropAndScaleStrategy.CROP_FIRST,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      const pixelSize = (await pixels.getImageInfo()).size;
      if (pixelSize.width !== MODEL_SIZE || pixelSize.height !== MODEL_SIZE) {
        throw new Error('图像模型输入尺寸不正确');
      }
      const rgba = new Uint8Array(pixels.getPixelBytesNumber());
      await pixels.readPixelsToBuffer(rgba.buffer);
      let animeScore = 0;
      let cutoff = wallpaperThreshold(size.width, size.height);
      if ((fits || tryReaction || this.knowledge) && !this.animeUnavailable) {
        try {
          const scores = await this.anime.rank(context, rgba);
          animeScore = animeArtworkScore(scores);
          if (this.knowledge && looksLikeHandwrittenNotes(scores)) {
            return new SceneMatch('知识', '画面有手写知识笔记线索');
          }
          const soft = hasSoftEdges(rgba, MODEL_SIZE);
          cutoff += soft ? 0.06 : 0;
          const match = this.matchArtwork(scores, rgba, size, textLength, wallpaperSize, soft, fits, cutoff, tryReaction);
          if (match !== undefined) {
            return match;
          }
          const maybeReaction = tryReaction && textLength > 0 && textLength <= 260 && hasReactionEvidence(scores);
          const ratio = Math.max(size.width, size.height) / edge;
          const retryWallpaper = ratio >= 1.35 && fits && animeScore >= (textLength === 0 ? 0.05 : 0.11);
          if (retryWallpaper || (collage && animeScore >= 0.60) || (ratio >= 1.24 && maybeReaction)) {
            try {
              const fullFrame = await readFullFrame(source, size);
              const full = await this.anime.rank(context, fullFrame);
              const retry = this.matchArtwork(full, fullFrame, size, textLength, wallpaperSize, soft, fits, cutoff, tryReaction);
              if (retry !== undefined) {
                return new SceneMatch(retry.category, retry.hint + ' · 全图复判');
              }
              animeScore = Math.max(animeScore, animeArtworkScore(full));
            } catch (_error) {
              // Use the center analysis if this decoder does not support a full-frame preview.
            }
          }
        } catch (_error) {
          this.animeUnavailable = true;
        }
      }
      const reviewHint = screenshot ? '截图不归入壁纸' : this.wallpaperHint(size.width, size.height, animeScore, fits, cutoff);
      if (!this.landscape && (this.naturalWallpaperCategory.length === 0 || !fits)) {
        return new SceneMatch(REVIEW_CATEGORY, reviewHint);
      }
      if (this.loadingModel === undefined) {
        this.loadingModel = context.resourceManager.getRawFileContent(MODEL_RESOURCE)
          .then(bytes => mindSporeLite.loadModelFromBuffer(new Uint8Array(bytes).buffer, {
            target: ['cpu'],
            cpu: { threadNum: 2 }
          }));
      }
      const model = await this.loadingModel;
      const inputs = model.getInputs();
      const shape = inputs[0]?.shape;
      if (inputs.length !== 1 || inputs[0].dtype !== mindSporeLite.DataType.NUMBER_TYPE_FLOAT32 ||
        !shape || shape.length !== 4 || shape[0] !== 1 || shape[1] !== MODEL_SIZE ||
        shape[2] !== MODEL_SIZE || shape[3] !== 3) {
        throw new Error('图像模型输入格式不受支持');
      }
      const input = inputs[0];
      const rgb = new Float32Array(MODEL_SIZE * MODEL_SIZE * 3);
      for (let channel = 0, pixel = 0; channel < rgb.length; channel += 3, pixel += 4) {
        rgb[channel] = rgba[pixel] / 127.5 - 1;
        rgb[channel + 1] = rgba[pixel + 1] / 127.5 - 1;
        rgb[channel + 2] = rgba[pixel + 2] / 127.5 - 1;
      }
      input.setData(rgb.buffer);
      const outputs = await model.predict(inputs);
      if (outputs.length !== 1 || outputs[0].dtype !== mindSporeLite.DataType.NUMBER_TYPE_FLOAT32 ||
        outputs[0].elementNum !== LABEL_COUNT) {
        throw new Error('图像模型输出格式不受支持');
      }
      const scores = new Float32Array(outputs[0].getData());
      let strongest = 0;
      let landscapeScore = 0;
      for (let index = 0; index < scores.length; index++) {
        if (scores[index] > scores[strongest]) {
          strongest = index;
        }
        if (LANDSCAPE_LABELS.has(index)) {
          landscapeScore += scores[index];
        }
      }
      if (!LANDSCAPE_LABELS.has(strongest) || (scores[strongest] < 0.28 &&
        (scores[strongest] < 0.18 || landscapeScore < 0.5))) {
        return new SceneMatch(REVIEW_CATEGORY, reviewHint);
      }
      const ratio = size.width / size.height;
      if (!screenshot && this.naturalWallpaperCategory.length > 0 && textLength <= 7 && size.width >= 720 &&
        size.height >= 1280 && ratio >= 0.43 && ratio <= 0.60) {
        return new SceneMatch(this.naturalWallpaperCategory, '识别到风景，符合竖屏壁纸比例');
      }
      return this.landscape ? new SceneMatch('风景', '识别到自然风景') : new SceneMatch(REVIEW_CATEGORY, reviewHint);
    } finally {
      try {
        await pixels?.release();
      } finally {
        try {
          await source?.release();
        } finally {
          await fileIo.close(file);
        }
      }
    }
  }

  private matchArtwork(scores: Float32Array, rgba: Uint8Array, size: image.Size, textLength: number, wallpaperSize: boolean,
    soft: boolean, fits: boolean, cutoff: number, tryReaction: boolean): SceneMatch | undefined {
    const compact = Math.max(size.width, size.height) <= 960;
    const squareSticker = tryReaction && textLength <= 2 &&
      Math.abs(size.width / size.height - 1) <= 0.05 && looksLikeSquareSticker(scores, rgba, MODEL_SIZE);
    const sceneMeme = tryReaction && textLength <= 260 && looksLikeSceneMeme(scores, textLength, wallpaperSize, compact);
    if (squareSticker || sceneMeme ||
      (tryReaction && textLength <= 75 && looksLikeReaction(scores, textLength, wallpaperSize, soft, compact))) {
      let hint = textLength >= 4 ? '画面和文字有表情或对白线索' : '画面有表情包线索';
      if (!wallpaperSize) {
        hint += ' · 非壁纸尺寸';
      }
      if (soft) {
        hint += ' · 画面偏模糊';
      }
      return this.reactionCategory.length > 0 ? new SceneMatch(this.reactionCategory, hint) :
        new SceneMatch(REVIEW_CATEGORY, '疑似聊天表情，建议手动确认');
    }
    if (wallpaperSize && this.animeCategory.length > 0 && size.width < size.height &&
      looksLikeAnimeCollage(scores, textLength)) {
      return new SceneMatch(this.animeCategory, '动漫拼贴 · 符合手机壁纸尺寸');
    }
    if (fits && animeArtworkScore(scores) >= cutoff) {
      return new SceneMatch(this.animeCategory, size.width < size.height ?
        '动漫插画 · 符合手机壁纸尺寸' : '动漫插画 · 符合电脑壁纸尺寸');
    }
    return undefined;
  }

  private wallpaperHint(width: number, height: number, score: number, fits: boolean,
    cutoff: number = ANIME_THRESHOLD): string {
    if (this.animeCategory.length === 0) {
      return '';
    }
    if (fits) {
      return this.animeUnavailable ? '动漫识别暂不可用' :
        '动漫得分 ' + Math.floor(score * 100) + '/100，门槛 ' + Math.round(cutoff * 100);
    }
    return fitsWallpaperSize(width, height) ? '文字较多，跳过壁纸判断' :
      '壁纸尺寸或比例不符（' + width + ' × ' + height + '）';
  }
}
