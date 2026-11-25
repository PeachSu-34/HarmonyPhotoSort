import { dataSharePredicates } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

export class AlbumArchiveResult {
  readonly confirmed: Set<string> = new Set<string>();
  copied: number = 0;
  existing: number = 0;
  issue: string = '';
}

function byUri(uri: string): photoAccessHelper.FetchOptions {
  const predicates = new dataSharePredicates.DataSharePredicates();
  predicates.equalTo(photoAccessHelper.PhotoKeys.URI, uri);
  return { fetchColumns: [], predicates: predicates };
}

export class ExistingAlbums {
  private readonly copied: Map<string, Set<string>> = new Map<string, Set<string>>();

  async list(helper: photoAccessHelper.PhotoAccessHelper): Promise<photoAccessHelper.Album[]> {
    const albums = await helper.getAlbums(photoAccessHelper.AlbumType.USER, photoAccessHelper.AlbumSubtype.USER_GENERIC);
    try {
      return await albums.getAllObjects();
    } finally {
      albums.close();
    }
  }

  async archive(helper: photoAccessHelper.PhotoAccessHelper, album: photoAccessHelper.Album,
    uris: string[]): Promise<AlbumArchiveResult> {
    const result = new AlbumArchiveResult();
    const previous = this.copied.get(album.albumUri) ?? new Set<string>();
    this.copied.set(album.albumUri, previous);
    for (let offset = 0; offset < uris.length; offset += 150) {
      const assets: photoAccessHelper.PhotoAsset[] = [];
      const sources: string[] = [];
      for (const uri of uris.slice(offset, offset + 150)) {
        try {
          if (previous.has(uri)) {
            result.confirmed.add(uri);
            result.existing++;
            continue;
          }
          const inAlbum = await album.getAssets(byUri(uri));
          let existing: boolean;
          try {
            existing = inAlbum.getCount() > 0;
          } finally {
            inAlbum.close();
          }
          if (existing) {
            result.confirmed.add(uri);
            result.existing++;
            continue;
          }
          const photos = await helper.getAssets(byUri(uri));
          try {
            if (photos.getCount() > 0) {
              assets.push(await photos.getFirstObject());
              sources.push(uri);
            }
          } finally {
            photos.close();
          }
        } catch (error) {
          result.issue = (error as BusinessError).message;
        }
      }
      if (assets.length > 0) {
        try {
          const change = new photoAccessHelper.MediaAlbumChangeRequest(album);
          change.addAssets(assets);
          await helper.applyChanges(change);
          result.copied += sources.length;
          sources.forEach(uri => { previous.add(uri); result.confirmed.add(uri); });
        } catch (error) {
          result.issue = (error as BusinessError).message;
        }
      }
    }
    return result;
  }
}
