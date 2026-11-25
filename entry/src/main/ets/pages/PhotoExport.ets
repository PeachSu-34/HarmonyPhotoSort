import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

export const EXPORT_LIMIT: number = 100;

export function photoDisplayName(uri: string): string {
  const segment = uri.split('/').pop() ?? '';
  try {
    return decodeURIComponent(segment);
  } catch (_error) {
    return segment;
  }
}

function creationConfig(uri: string, group: string): photoAccessHelper.PhotoCreationConfig {
  const name = photoDisplayName(uri);
  const dot = name.lastIndexOf('.');
  if (dot <= 0 || !/^[a-z0-9]{2,8}$/i.test(name.slice(dot + 1))) {
    throw new Error('这张照片的文件格式无法确认。');
  }
  return {
    photoType: photoAccessHelper.PhotoType.IMAGE,
    fileNameExtension: name.slice(dot + 1).toLowerCase(),
    title: (group + ' - ' + name.slice(0, dot)).replace(/[\x00-\x1F\\/:*?"'\x60<>|{}\[\].]/g, '_').slice(0, 64)
  };
}

export class PhotoExport {
  private pending: Map<string, string> = new Map<string, string>();

  async authorizeBatch(context: common.UIAbilityContext, uris: string[], group: string): Promise<boolean> {
    const remaining = uris.filter(uri => !this.pending.has(uri));
    if (remaining.length === 0) {
      return true;
    }
    const helper = photoAccessHelper.getPhotoAccessHelper(context);
    const destinations = await helper.showAssetsCreationDialog(remaining, remaining.map(uri => creationConfig(uri, group)));
    if (destinations.length === 0) {
      return false;
    }
    destinations.forEach((uri, index) => {
      if (index < remaining.length && uri.startsWith('file://media/')) {
        this.pending.set(remaining[index], uri);
      }
    });
    return true;
  }

  async save(context: common.UIAbilityContext, uri: string, group: string, single: boolean): Promise<void> {
    const source = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    let destination: fileIo.File | undefined;
    try {
      let target = this.pending.get(uri);
      if (target === undefined && single) {
        const config = creationConfig(uri, group);
        const helper = photoAccessHelper.getPhotoAccessHelper(context);
        target = await helper.createAsset(config.photoType, config.fileNameExtension, { title: config.title });
        this.pending.set(uri, target);
      }
      if (target === undefined) {
        throw new Error('系统未授权保存这张照片。');
      }
      destination = await fileIo.open(target, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      await fileIo.copyFile(source.fd, destination.fd);
      this.pending.delete(uri);
    } finally {
      try {
        if (destination !== undefined) {
          await fileIo.close(destination);
        }
      } finally {
        await fileIo.close(source);
      }
    }
  }

  retain(uris: string[]): void {
    const selected = new Set(uris);
    this.pending.forEach((_target, source) => {
      if (!selected.has(source)) {
        this.pending.delete(source);
      }
    });
  }
}
