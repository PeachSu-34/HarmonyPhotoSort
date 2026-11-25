import { photoDisplayName } from './PhotoExport';

export class PhotoRow {
  readonly group: string;
  readonly uri: string;
  readonly count: number;

  constructor(group: string, uri: string = '', count: number = 0) {
    this.group = group;
    this.uri = uri;
    this.count = count;
  }

  key(): string {
    return this.uri.length > 0 ? JSON.stringify([this.group, this.uri]) :
      JSON.stringify([this.group, this.count]);
  }
}

export class PhotoRows implements IDataSource {
  private rows: PhotoRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number { return this.rows.length; }

  getData(index: number): PhotoRow { return this.rows[index]; }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter(item => item !== listener);
  }

  update(rows: PhotoRow[]): void {
    this.rows = rows;
    this.listeners.forEach(listener => listener.onDataReloaded());
  }

  neighbor(uri: string): string {
    const index = this.rows.findIndex(row => row.uri === uri);
    if (index < 0) {
      return '';
    }
    return this.rows.slice(index + 1).find(row => row.uri.length > 0)?.uri ??
      this.rows.slice(0, index).reverse().find(row => row.uri.length > 0)?.uri ?? '';
  }

  indexOf(uri: string): number { return this.rows.findIndex(row => row.uri === uri); }

  photos(): PhotoRow[] { return this.rows.filter(row => row.uri.length > 0); }
}

export function findScreenshots(uris: string[]): Set<string> {
  return new Set(uris.filter(uri => /(?:screenshots?(?:[%_/.-]|$)|截屏|截图)/i.test(photoDisplayName(uri))));
}
