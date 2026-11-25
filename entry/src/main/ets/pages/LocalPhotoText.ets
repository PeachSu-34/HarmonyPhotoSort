import { textRecognition } from '@kit.CoreVisionKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';

export class PhotoTextError extends Error {
  readonly code: number | undefined;

  constructor(step: string, code: number | undefined) {
    super(step + '失败' + (code === undefined ? '' : '，错误码 ' + code));
    this.code = code;
  }
}

export class PhotoReading {
  readonly text: string;
  readonly animatedGif: boolean;

  constructor(text: string, animatedGif: boolean = false) {
    this.text = text;
    this.animatedGif = animatedGif;
  }
}

export async function readPhotoText(uri: string): Promise<string> {
  return (await readPhoto(uri, false)).text;
}

export async function readPhoto(uri: string, detectGif: boolean): Promise<PhotoReading> {
  let file: fileIo.File | undefined;
  let step = '读取图片';
  try {
    file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    step = '打开图片解码器';
    const source = image.createImageSource(file.fd);
    if (detectGif) {
      let animated = false;
      try {
        const info = await source.getImageInfo();
        animated = info.mimeType === 'image/gif' && await source.getFrameCount() > 1;
      } catch (_error) {
        // OCR still works on decoders that do not expose frame information.
      }
      if (animated) {
        await source.release();
        return new PhotoReading('', true);
      }
    }
    return new PhotoReading(await recognizePhotoSource(source));
  } catch (error) {
    if (error instanceof PhotoTextError) {
      throw error;
    }
    throw new PhotoTextError(step, (error as BusinessError).code);
  } finally {
    if (file !== undefined) {
      try {
        await fileIo.close(file);
      } catch (_error) {
        // A cleanup error must not replace a completed OCR result.
      }
    }
  }
}

export async function recognizePhotoSource(source: image.ImageSource): Promise<string> {
  try {
    let size: image.Size;
    try {
      size = (await source.getImageInfo()).size;
    } catch (error) {
      throw new PhotoTextError('解码图片', (error as BusinessError).code);
    }
    const shortSide = Math.min(size.width, size.height);
    const longSide = Math.max(size.width, size.height);
    const scale = Math.min(2560 / longSide, Math.max(1, 128 / shortSide));
    try {
      return await recognizePixels(source, {
        desiredSize: scaledSize(size, scale),
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
    } catch (error) {
      if (!(error instanceof PhotoTextError) || (error.code !== 200 && error.code !== 1001400001)) {
        throw error as Error;
      }
      if (error.code === 200 && longSide >= 1200 && shortSide >= 480) {
        // A bounded retry reads the header and first rows without shrinking small text first.
        const region: image.Size = { width: Math.ceil(size.width * 0.72), height: Math.ceil(size.height * 0.48) };
        return await recognizePixels(source, {
          desiredRegion: { x: 0, y: 0, size: region },
          desiredSize: scaledSize(region, Math.min(1, 1700 / Math.max(region.width, region.height))),
          cropAndScaleStrategy: image.CropAndScaleStrategy.CROP_FIRST,
          desiredPixelFormat: image.PixelMapFormat.RGBA_8888
        });
      }
      const retryScale = shortSide < 256 ? Math.min(256 / shortSide, 2304 / longSide) : Math.min(1, 1600 / longSide);
      return await recognizePixels(source, {
        desiredSize: scaledSize(size, retryScale),
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
    }
  } finally {
    try {
      await source.release();
    } catch (_error) {
      // Preserve the OCR result or the original error.
    }
  }
}

function scaledSize(size: image.Size, scale: number): image.Size {
  return {
    width: Math.max(1, Math.round(size.width * scale)),
    height: Math.max(1, Math.round(size.height * scale))
  };
}

async function recognizePixels(source: image.ImageSource, options: image.DecodingOptions): Promise<string> {
  let pixels: image.PixelMap | undefined;
  let step = '解码图片';
  try {
    pixels = await source.createPixelMap(options);
    step = '识别文字';
    const result = await textRecognition.recognizeText({ pixelMap: pixels });
    const text = result.value ?? '';
    return text.trim().length > 0 ? text : (result.blocks ?? [])
      .map(block => block.value || (block.lines ?? []).map(line => line.value).join('\n')).join('\n');
  } catch (error) {
    throw new PhotoTextError(step, (error as BusinessError).code);
  } finally {
    try {
      await pixels?.release();
    } catch (_error) {
      // Preserve the result of this OCR attempt.
    }
  }
}
