import { common } from '@kit.AbilityKit';
import { isAnimeArtwork } from './WallpaperRules';

const MODEL = 'photosort_model/tinyclip-int8.onnx';
const IMAGE_AREA = 224 * 224;
const MEANS: number[] = [0.48145466, 0.4578275, 0.40821073];
const DEVIATIONS: number[] = [0.26862954, 0.26130258, 0.27577711];

interface SceneRuntime {
  rankScenes(model: ArrayBuffer, pixels: ArrayBuffer): Promise<Float32Array>;
}

export class LocalAnimeWallpaper {
  private static loaded: boolean = false;
  private static runtime?: SceneRuntime;

  async matches(context: common.UIAbilityContext, rgba: Uint8Array): Promise<boolean> {
    return isAnimeArtwork(await this.rank(context, rgba));
  }

  async rank(context: common.UIAbilityContext, rgba: Uint8Array): Promise<Float32Array> {
    if (LocalAnimeWallpaper.runtime === undefined) {
      LocalAnimeWallpaper.runtime = loadNativeModule('libphotosort_ort.so') as SceneRuntime;
    }
    let model = new ArrayBuffer(0);
    if (!LocalAnimeWallpaper.loaded) {
      const bytes = await context.resourceManager.getRawFileContent(MODEL);
      model = new ArrayBuffer(bytes.length);
      new Uint8Array(model).set(bytes);
    }
    const buffer = new ArrayBuffer(IMAGE_AREA * 3 * Float32Array.BYTES_PER_ELEMENT);
    const rgb = new Float32Array(buffer);
    for (let channel = 0; channel < 3; channel++) {
      for (let pixel = 0; pixel < IMAGE_AREA; pixel++) {
        rgb[channel * IMAGE_AREA + pixel] = (rgba[pixel * 4 + channel] / 255 - MEANS[channel]) / DEVIATIONS[channel];
      }
    }
    const scores = await LocalAnimeWallpaper.runtime.rankScenes(model, buffer);
    LocalAnimeWallpaper.loaded = true;
    return scores;
  }
}
