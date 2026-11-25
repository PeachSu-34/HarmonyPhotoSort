import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { matchCategory, parseCategories, REVIEW_CATEGORY, TRASH_CATEGORY } from './CategoryRules';
import { LocalPhotoScene } from './LocalPhotoScene';
import { readPhoto } from './LocalPhotoText';
import { LocalTextSemantic } from './LocalTextSemantic';
import { findScreenshots, PhotoRow, PhotoRows } from './PhotoBatch';
import { PhotoBackground } from './PhotoBackground';
import { EXPORT_LIMIT, PhotoExport, photoDisplayName } from './PhotoExport';
import { ExistingAlbums } from './ExistingAlbums';

const INITIAL_CATEGORIES: string = '信息\n知识\n动漫壁纸\n表情包';
const BATCH_LIMIT: number = 999;
const TRASH_PERMISSION: Permissions = 'ohos.permission.WRITE_IMAGEVIDEO';
const ALBUM_READ_PERMISSION: Permissions = 'ohos.permission.READ_IMAGEVIDEO';

class PhotoGroup {
  readonly name: string;
  readonly uris: string[];
  constructor(name: string, uris: string[]) {
    this.name = name;
    this.uris = uris;
  }
}

@Component
struct PhotoPreviewSlide {
  uri: string = '';
  @State private failed: boolean = false;

  build() {
    Stack() {
      if (this.failed) {
        Text('无法加载这张照片').fontColor('#DDDDDD').fontSize(16)
      } else {
        Image(this.uri)
          .width('100%').height('100%').objectFit(ImageFit.Contain)
          .syncLoad(false).draggable(false).accessibilityText('照片预览')
          .onError(() => { this.failed = true; })
      }
    }
    .width('100%').height('100%')
  }
}

@Entry
@Component
struct Index {
  @StorageProp('photoSortSmokeStatus') private smokeStatus: string = '';
  @State private selectedUris: string[] = [];
  @State private categoryInput: string = INITIAL_CATEGORIES;
  @State private status: string = '先用系统选图器选一批照片。';
  @State private groups: PhotoGroup[] = [];
  @State private photoHints: Map<string, string> = new Map<string, string>();
  @State private busy: boolean = false;
  @State private progressDone: number = 0;
  @State private classifying: boolean = false;
  @State private previewPosition: number = 0;
  @State private previewTotal: number = 0;
  @State private previewVisible: boolean = false;
  @State private resultsVisible: boolean = true;
  private previewRows: PhotoRows = new PhotoRows();
  private previewStart: number = 0;
  private revealRequest: number = 0;
  @State private movingUri: string = '';
  @State private selectionGroup: string = '';
  @State private checkedUris: string[] = [];
  @State private albumSheetVisible: boolean = false;
  @State private archiveGroup: string = '';
  @State private albumNames: string[] = [];
  @State private albumTargets: Map<string, string> = new Map<string, string>();
  private readonly deniedAlbumPermissions: Set<Permissions> = new Set<Permissions>();
  private albums: photoAccessHelper.Album[] = [];
  private readonly existingAlbums: ExistingAlbums = new ExistingAlbums();
  @State private needsTrashPermission: boolean = false;
  @State private feedback: string = '';
  private feedbackTimer: number = -1;
  private readonly photoExport: PhotoExport = new PhotoExport();
  private rows: PhotoRows = new PhotoRows();
  private listScroller: Scroller = new Scroller();
  private anchorRequest: number = 0;

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private async openGalleryForTrash(): Promise<void> {
    try {
      await this.context().startAbility({
        bundleName: 'com.huawei.hmos.photos',
        abilityName: 'com.huawei.hmos.photos.MainAbility'
      });
    } catch (_error) {
      this.showFeedback('请手动打开系统图库，核对并删除对应原照片。');
    }
  }

  private async choosePhotos(append: boolean = false): Promise<void> {
    this.busy = true;
    try {
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = Math.min(500, BATCH_LIMIT - (append ? this.selectedUris.length : 0));
      const result = await new photoAccessHelper.PhotoViewPicker().select(options);
      if (result.photoUris.length > 0) {
        this.revealRequest++;
        this.resultsVisible = true;
        const picked = Array.from(new Set((append ? this.selectedUris : []).concat(result.photoUris))).slice(0, BATCH_LIMIT);
        this.photoExport.retain(picked);
        this.getUIContext().animateTo({ duration: 170, curve: Curve.EaseOut }, () => {
          this.selectedUris = picked;
          this.groups = [];
          this.clearSelection();
          this.refreshRows();
          this.photoHints = new Map<string, string>();
          this.status = '已选 ' + picked.length + ' / ' + BATCH_LIMIT + ' 张';
        });
      }
    } catch (error) {
      this.showError('选图', error as BusinessError);
    } finally {
      this.busy = false;
    }
  }

  private async classify(): Promise<void> {
    this.busy = true;
    try {
      const rules = parseCategories(this.categoryInput);
      this.progressDone = 0;
      this.revealRequest++;
      this.classifying = true;
      this.status = '正在离线分类';
      PhotoBackground.begin();
      const scene = new LocalPhotoScene(rules);
      const semantic = new LocalTextSemantic(rules);
      const gifCategory = rules.find(rule => /^(表情包|聊天表情|梗图)$/.test(rule.name))?.name ?? '';
      const screenshotUris = findScreenshots(this.selectedUris);
      const manualTrash = new Set(this.groups.find(group => group.name === TRASH_CATEGORY)?.uris ?? []);
      const names = rules.map(rule => rule.name).concat([REVIEW_CATEGORY, TRASH_CATEGORY]);
      const grouped = new Map<string, string[]>();
      const hints = new Map<string, string>();
      for (const name of names) {
        grouped.set(name, []);
      }
      let unreadable = 0;
      let semanticFailed = false;
      for (let i = 0; i < this.selectedUris.length; i++) {
        const uri = this.selectedUris[i];
        if (manualTrash.has(uri)) {
          grouped.get(TRASH_CATEGORY)?.push(uri);
          hints.set(uri, '已手动加入删除');
          this.progressDone = i + 1;
          continue;
        }
        const screenshot = screenshotUris.has(uri);
        let category = REVIEW_CATEGORY;
        let textLength = 0;
        let hint = '';
        let text = '';
        try {
          const reading = await readPhoto(uri, gifCategory.length > 0);
          if (reading.animatedGif) {
            grouped.get(gifCategory)?.push(uri);
            hints.set(uri, 'GIF 动图');
            this.progressDone = i + 1;
            continue;
          }
          text = reading.text;
          textLength = text.replace(/\s/g, '').length;
          category = matchCategory(text, rules);
          hint = textLength > 0 ? '已读 ' + textLength + ' 字' : '未检测到文字';
          if (category !== REVIEW_CATEGORY) {
            hint += ' · 按关键词或文字规则归类';
          }
        } catch (error) {
          unreadable++;
          hint = this.errorText(error as BusinessError);
        }
        if (category === REVIEW_CATEGORY && !semanticFailed && semantic.shouldAnalyze(textLength)) {
          try {
            category = await semantic.classify(this.context(), text);
            if (category !== REVIEW_CATEGORY) {
              hint += ' · 按文字内容归类';
            } else if (semantic.getReviewHint().length > 0) {
              hint += ' · ' + semantic.getReviewHint();
            }
          } catch (_error) {
            semanticFailed = true;
          }
        }
        if (screenshot && /^(动漫壁纸|动画壁纸|二次元壁纸|壁纸|手机壁纸|锁屏壁纸|桌面壁纸)$/.test(category)) {
          category = REVIEW_CATEGORY;
          hint = '截图不归入壁纸';
        }
        if (category === REVIEW_CATEGORY && scene.shouldAnalyze(textLength)) {
          try {
            const match = await scene.classify(this.context(), uri, text, screenshot);
            category = match.category;
            if (match.hint.length > 0) {
              hint = match.category === REVIEW_CATEGORY ? hint + ' · ' + match.hint : match.hint;
            }
          } catch (error) {
            hint += ' · 图像识别失败 ' + this.errorText(error as BusinessError);
          }
        }
        hints.set(uri, category === REVIEW_CATEGORY ? hint + ' · 待确认' : hint);
        grouped.get(category)?.push(uri);
        this.progressDone = i + 1;
      }
      this.photoHints = hints;
      this.resultsVisible = false;
      this.groups = names.map(name => new PhotoGroup(name, grouped.get(name) ?? []));
      this.clearSelection();
      this.refreshRows();
      const reviewCount = grouped.get(REVIEW_CATEGORY)?.length ?? 0;
      this.status = '已完成分组，' + reviewCount + ' 张待确认。'
        + (unreadable > 0 ? '\n有 ' + unreadable + ' 张图片无法读取文字，可在预览中手动分组。' : '')
        + (semanticFailed ? '\n文字语义识别暂不可用，本次已使用关键词规则。' : '');
      this.revealResults();
    } catch (error) {
      this.showError('分类设置', error as BusinessError);
    } finally {
      PhotoBackground.finish();
      this.classifying = false;
      this.busy = false;
    }
  }

  private revealResults(): void {
    const request = this.revealRequest;
    setTimeout(() => {
      if (request !== this.revealRequest) {
        return;
      }
      this.getUIContext().animateTo({ duration: 210, curve: Curve.EaseOut }, () => {
        this.resultsVisible = true;
      });
      if (this.rows.totalCount() > 0) {
        this.listScroller.scrollToIndex(1, true, ScrollAlign.START);
      }
    }, 34);
  }

  private changeCategory(uri: string, from: string, to: string): void {
    if (from === to || this.movingUri.length > 0) {
      return;
    }
    const anchor = this.rows.neighbor(uri);
    this.getUIContext().animateTo({ duration: 105, curve: Curve.EaseOut, onFinish: () => {
      this.movePhoto(uri, from, to, anchor);
    } }, () => { this.movingUri = uri; });
  }

  private movePhoto(uri: string, from: string, to: string, anchor: string): void {
    if (this.busy) {
      this.movingUri = '';
      return;
    }
    this.groups = this.groups.map(group => {
      if (group.name === from) {
        return new PhotoGroup(group.name, group.uris.filter(item => item !== uri));
      }
      if (group.name === to) {
        return new PhotoGroup(group.name, group.uris.concat([uri]));
      }
      return group;
    });
    this.refreshRows();
    this.movingUri = '';
    this.centerPhoto(anchor);
  }

  private centerPhoto(anchor: string): void {
    const request = ++this.anchorRequest;
    if (anchor.length > 0) {
      setTimeout(() => {
        const index = this.rows.indexOf(anchor);
        if (request === this.anchorRequest && index >= 0) {
          this.listScroller.scrollToIndex(index + 1, true, ScrollAlign.CENTER);
        }
      }, 34);
    }
  }

  private refreshRows(): void {
    const rows: PhotoRow[] = [];
    for (const group of this.groups) {
      if (group.uris.length > 0 || group.name === TRASH_CATEGORY) {
        rows.push(new PhotoRow(group.name, '', group.uris.length));
        group.uris.forEach(uri => rows.push(new PhotoRow(group.name, uri)));
      }
    }
    this.rows.update(rows);
  }

  private clearSelection(): void {
    this.selectionGroup = '';
    this.checkedUris = [];
  }

  private toggleChecked(uri: string, checked: boolean): void {
    if (checked === this.checkedUris.includes(uri)) {
      return;
    }
    this.checkedUris = checked ? this.checkedUris.concat([uri]) : this.checkedUris.filter(item => item !== uri);
  }

  private archiveUris(): string[] {
    const groupName = this.archiveGroup || this.selectionGroup;
    const group = this.groups.find(item => item.name === groupName);
    if (group === undefined || group.name === TRASH_CATEGORY) {
      return [];
    }
    if (this.archiveGroup.length > 0) {
      return group.uris.slice();
    }
    const checked = new Set(this.checkedUris);
    return group.uris.filter(uri => checked.has(uri));
  }

  private openArchivePicker(groupName: string = ''): void {
    if (this.busy) {
      return;
    }
    this.archiveGroup = groupName;
    this.albumSheetVisible = this.archiveUris().length > 0;
  }

  private async requestAlbumPermission(permission: Permissions): Promise<boolean> {
    const manager = abilityAccessCtrl.createAtManager();
    const results = this.deniedAlbumPermissions.has(permission) ?
      await manager.requestPermissionOnSetting(this.context(), [permission]) :
      (await manager.requestPermissionsFromUser(this.context(), [permission])).authResults;
    const granted = results[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    if (granted) {
      this.deniedAlbumPermissions.delete(permission);
    } else {
      this.deniedAlbumPermissions.add(permission);
      this.status = '未获得相册权限，可再次点击打开系统授权。';
      this.showFeedback(this.status);
    }
    return granted;
  }

  private async loadExistingAlbums(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      if (!await this.requestAlbumPermission(ALBUM_READ_PERMISSION)) {
        return;
      }
      this.albums = await this.existingAlbums.list(photoAccessHelper.getPhotoAccessHelper(this.context()));
      this.albumNames = this.albums.map(album => album.albumName);
      this.status = this.albums.length > 0 ? '请为要归档的分类选择目标相册。' : '图库中没有已有的用户相册。';
      if (this.albums.length === 0) {
        this.showFeedback(this.status);
      }
    } catch (error) {
      this.showError('读取已有相册', error as BusinessError);
      this.showFeedback(this.status);
    } finally {
      this.busy = false;
    }
  }

  private albumIndex(group: string): number {
    return this.albums.findIndex(album => album.albumUri === this.albumTargets.get(group));
  }

  private selectedAlbumName(group: string): string {
    return this.albumNames[this.albumIndex(group)] ?? '选择目标相册';
  }

  private setAlbumTarget(group: string, index: number): void {
    const album = this.albums[index];
    if (album !== undefined) {
      const targets = new Map<string, string>(this.albumTargets);
      targets.set(group, album.albumUri);
      this.albumTargets = targets;
    }
  }

  private mappedCount(): number {
    return this.groups.filter(group => group.name !== TRASH_CATEGORY && this.albumIndex(group.name) >= 0)
      .reduce((count, group) => count + group.uris.length, 0);
  }

  private async archiveToExisting(allGroups: boolean): Promise<void> {
    if (this.busy) {
      return;
    }
    const groupName = this.archiveGroup || this.selectionGroup;
    const selected = allGroups ? [] : this.archiveUris();
    const groups = this.groups.filter(group => group.name !== TRASH_CATEGORY && group.uris.length > 0 &&
      (allGroups || group.name === groupName) && this.albumIndex(group.name) >= 0);
    if (groups.length === 0 || (!allGroups && selected.length === 0)) {
      return;
    }
    this.busy = true;
    try {
      if (!await this.requestAlbumPermission(ALBUM_READ_PERMISSION) ||
        !await this.requestAlbumPermission(TRASH_PERMISSION)) {
        return;
      }
      this.albumSheetVisible = false;
      const helper = photoAccessHelper.getPhotoAccessHelper(this.context());
      let copied = 0;
      let existing = 0;
      let failed = 0;
      let issue = '';
      for (const group of groups) {
        const uris = allGroups ? group.uris : selected;
        const result = await this.existingAlbums.archive(helper, this.albums[this.albumIndex(group.name)], uris);
        copied += result.copied;
        existing += result.existing;
        failed += uris.length - result.confirmed.size;
        if (result.issue.length > 0) {
          issue = result.issue;
        }
        if (!allGroups && this.archiveGroup.length === 0) {
          this.removeFromBatch(result.confirmed);
        }
      }
      const summary = '已归档 ' + copied + ' 张' + (existing > 0 ? '，已在目标相册 ' + existing + ' 张' : '') +
        (failed > 0 ? '，' + failed + ' 张未归档' : '') + '。';
      this.status = summary + (issue.length > 0 ? '\n' + issue : '');
      this.showFeedback(summary);
    } catch (error) {
      this.showError('归档到已有相册', error as BusinessError);
      this.showFeedback(this.status);
    } finally {
      this.busy = false;
    }
  }

  private removeFromBatch(uris: Set<string>): void {
    if (uris.size === 0) {
      return;
    }
    this.selectedUris = this.selectedUris.filter(uri => !uris.has(uri));
    this.groups = this.groups.map(group => new PhotoGroup(group.name, group.uris.filter(uri => !uris.has(uri))));
    this.checkedUris = this.checkedUris.filter(uri => !uris.has(uri));
    if (this.checkedUris.length === 0) {
      this.clearSelection();
    }
    this.refreshRows();
  }

  private async archiveSelection(single: boolean): Promise<void> {
    if (this.busy) {
      return;
    }
    const groupName = this.archiveGroup || this.selectionGroup;
    const uris = this.archiveUris().slice(0, EXPORT_LIMIT);
    if (uris.length === 0 || (single && uris.length !== 1)) {
      return;
    }
    this.albumSheetVisible = false;
    this.busy = true;
    const saved = new Set<string>();
    let failed = 0;
    let issue = '';
    try {
      if (!single && !await this.photoExport.authorizeBatch(this.context(), uris, groupName)) {
        this.showFeedback('已取消保存。');
        return;
      }
      for (const uri of uris) {
        try {
          await this.photoExport.save(this.context(), uri, groupName, single);
          saved.add(uri);
        } catch (error) {
          failed++;
          issue = this.errorText(error as BusinessError);
        }
      }
      const summary = '已保存 ' + saved.size + ' 张副本' + (failed > 0 ? '，' + failed + ' 张未保存' : '') + '。';
      this.status = summary + (issue.length > 0 ? '\n' + issue : '');
      this.showFeedback(summary);
    } catch (error) {
      this.showError('保存到图库', error as BusinessError);
      this.showFeedback(this.status);
    } finally {
      this.removeFromBatch(saved);
      this.busy = false;
    }
  }

  private confirmTrash(): void {
    const uris = this.groups.find(group => group.name === TRASH_CATEGORY)?.uris.slice() ?? [];
    if (uris.length === 0 || this.busy) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '移到最近删除？',
      message: '将手动放入「删除」的 ' + uris.length + ' 张原照片移到系统图库的「最近删除」。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '移到最近删除', fontColor: $r('app.color.danger_text'),
        action: () => { void this.trashPhotos(uris); } }
    });
  }

  private trashCount(): number {
    return this.groups.find(group => group.name === TRASH_CATEGORY)?.uris.length ?? 0;
  }

  private async openTrashPermissionSettings(): Promise<void> {
    if (this.busy || !this.needsTrashPermission || this.trashCount() === 0) {
      return;
    }
    this.busy = true;
    try {
      const results = await abilityAccessCtrl.createAtManager().requestPermissionOnSetting(this.context(),
        [TRASH_PERMISSION]);
      this.needsTrashPermission = results[0] !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      this.status = this.needsTrashPermission ? '尚未允许图库写权限，原照片仍在图库。' :
        '已获图库写权限，请重新确认要移到「最近删除」的照片。';
    } catch (error) {
      this.status = '无法打开授权页。请在「设置 › 应用和元服务 › 照片归类 › 权限」中检查图片和视频权限。';
    } finally {
      this.busy = false;
      this.showFeedback(this.status);
    }
  }

  private async trashPhotos(uris: string[]): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    const moved = new Set<string>();
    try {
      const permission = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(this.context(),
        [TRASH_PERMISSION]);
      this.needsTrashPermission = permission.authResults[0] !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      if (this.needsTrashPermission) {
        this.status = '图库写权限未开启。点「去系统授权」开启后，再确认删除。';
        return;
      }
      for (let offset = 0; offset < uris.length; offset += 300) {
        const batch = uris.slice(offset, offset + 300);
        await photoAccessHelper.MediaAssetChangeRequest.deleteAssets(this.context(), batch);
        batch.forEach(uri => moved.add(uri));
      }
      this.status = '已将 ' + moved.size + ' 张原照片移到「最近删除」。';
    } catch (error) {
      this.needsTrashPermission = (error as BusinessError).code === 201;
      this.status = '已移到最近删除 ' + moved.size + ' 张，其余仍在删除分组。' + this.errorText(error as BusinessError);
    } finally {
      if (moved.size > 0) {
        this.selectedUris = this.selectedUris.filter(uri => !moved.has(uri));
        this.groups = this.groups.map(group => new PhotoGroup(group.name,
          group.uris.filter(uri => !moved.has(uri))));
        moved.forEach(uri => this.photoHints.delete(uri));
        this.refreshRows();
      }
      this.busy = false;
      this.getUIContext().getPromptAction().showToast({ message: this.status });
    }
  }


  private showFeedback(message: string): void {
    if (this.feedbackTimer >= 0) {
      clearTimeout(this.feedbackTimer);
    }
    this.getUIContext().animateTo({ duration: 150, curve: Curve.EaseOut }, () => { this.feedback = message; });
    this.feedbackTimer = setTimeout(() => {
      this.getUIContext().animateTo({ duration: 130, curve: Curve.EaseIn }, () => { this.feedback = ''; });
      this.feedbackTimer = -1;
    }, 3500);
  }

  private errorText(error: BusinessError): string {
    return (error.code ? '错误码 ' + error.code + '。' : '') + error.message;
  }

  private showError(step: string, error: BusinessError): void {
    this.status = step + '失败。' + this.errorText(error);
  }


  private openPhotoPreview(uri: string): void {
    if (this.previewTotal > 0) {
      return;
    }
    const photos = this.rows.photos();
    const index = photos.findIndex(row => row.uri === uri);
    if (index < 0) {
      return;
    }
    this.previewRows.update(photos);
    this.previewStart = index;
    this.previewPosition = index;
    this.previewTotal = photos.length;
    this.previewVisible = true;
  }

  @Builder
  photoPreview() {
    Column() {
      Row() {
        Text((this.previewPosition + 1) + ' / ' + this.previewTotal)
          .fontSize(14).fontColor('#DDDDDD').accessibilityDescription('当前照片和总张数')
        Blank()
        Button('关闭')
          .height(44).padding({ left: 20, right: 20 })
          .backgroundColor('#333333').fontColor(Color.White)
          .onClick(() => { this.previewVisible = false; })
      }
      .justifyContent(FlexAlign.End).width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })

      Swiper() {
        LazyForEach(this.previewRows, (row: PhotoRow) => {
          PhotoPreviewSlide({ uri: row.uri })
        }, (row: PhotoRow) => row.uri)
      }
      .width('100%').layoutWeight(1)
      .index(this.previewStart).loop(false).indicator(false).cachedCount(1).duration(220)
      .onChange(index => { this.previewPosition = index; })
    }
    .width('100%').height('100%').backgroundColor('#101010')
  }

  @Builder
  groupHeader(row: PhotoRow) {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Text(row.group).fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(row.group === TRASH_CATEGORY ? $r('app.color.danger_text') : $r('app.color.main_text'))
        Text(row.count + ' 张').fontSize(13).fontColor($r('app.color.secondary_text'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 }).borderRadius(12).backgroundColor($r('app.color.summary'))
        Blank()
        if (row.group !== TRASH_CATEGORY) {
          Button(this.selectionGroup === row.group ? '结束多选' : '多选').fontSize(13)
            .enabled(!this.busy && this.movingUri.length === 0)
            .backgroundColor($r('app.color.summary')).fontColor($r('app.color.main_text'))
            .border({ width: 1, color: $r('app.color.outline') })
            .onClick(() => {
              const next = this.selectionGroup === row.group ? '' : row.group;
              this.getUIContext().animateTo({ duration: 140, curve: Curve.EaseOut }, () => {
                this.clearSelection();
                this.selectionGroup = next;
              });
            })
        }
      }
      .width('100%')
      if (row.group === TRASH_CATEGORY) {
        Text('手动归入后确认删除，原照片会进入系统「最近删除」。')
          .fontSize(13).fontColor($r('app.color.secondary_text'))
        if (row.count > 0) {
          Button('打开系统图库').fontSize(13).height(40).enabled(!this.busy)
            .backgroundColor($r('app.color.summary')).fontColor($r('app.color.main_text'))
            .onClick(() => { void this.openGalleryForTrash(); })
        }
      } else if (this.selectionGroup.length === 0 && row.count > 0) {
        Row({ space: 8 }) {
          if (this.albumNames.length > 0) {
            Select(this.albumNames.map(name => ({ value: name } as SelectOption)))
              .selected(this.albumIndex(row.group)).value(this.selectedAlbumName(row.group)).layoutWeight(1)
              .enabled(!this.busy).onSelect(index => { this.setAlbumTarget(row.group, index); })
          }
          Button('整组归档').fontSize(13).enabled(!this.busy && this.movingUri.length === 0)
            .backgroundColor($r('app.color.summary')).fontColor($r('app.color.main_text'))
            .border({ width: 1, color: $r('app.color.outline') })
            .onClick(() => { this.openArchivePicker(row.group); })
        }
        .width('100%')
      }
    }
    .padding({ top: 15, bottom: 5, left: 4, right: 4 }).width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  thumbnail(row: PhotoRow) {
    Image(row.uri).width(66).height(66).objectFit(ImageFit.Cover).borderRadius(12)
      .draggable(false).accessibilityLevel('no')
  }

  @Builder
  photoHint(row: PhotoRow) {
    Text(row.group === TRASH_CATEGORY ? photoDisplayName(row.uri) : this.photoHints.get(row.uri) ?? '')
      .fontSize(13).fontColor($r('app.color.secondary_text')).width('100%')
  }

  @Builder
  photoRow(row: PhotoRow) {
    if (this.selectionGroup === row.group) {
      Row({ space: 12 }) {
        Checkbox({ name: row.uri }).select(this.checkedUris.includes(row.uri))
          .selectedColor($r('app.color.accent')).accessibilityLevel('no').focusable(false)
          .hitTestBehavior(HitTestMode.None)
        this.thumbnail(row)
        Column({ space: 5 }) {
          Text(this.checkedUris.includes(row.uri) ? '已选中' : row.group)
            .fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.main_text')).width('100%')
          this.photoHint(row)
        }
        .layoutWeight(1)
      }
      .width('100%').constraintSize({ minHeight: 88 }).padding(10).borderRadius(18)
      .backgroundColor(this.checkedUris.includes(row.uri) ? $r('app.color.summary') : $r('app.color.panel'))
      .border({ width: 1, color: this.checkedUris.includes(row.uri) ? $r('app.color.accent') : $r('app.color.outline') })
      .focusable(true).accessibilityGroup(true).accessibilityText('选择照片')
      .accessibilityChecked(this.checkedUris.includes(row.uri))
      .onClick(() => {
        if (!this.busy) {
          this.getUIContext().animateTo({ duration: 115, curve: Curve.EaseOut }, () => {
            this.toggleChecked(row.uri, !this.checkedUris.includes(row.uri));
          });
        }
      })
    } else {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          this.thumbnail(row)
        }
        .width(66).height(66).padding(0).borderRadius(12).backgroundColor(Color.Transparent)
        .accessibilityText('查看大图').onClick(() => { this.openPhotoPreview(row.uri); })
        Column({ space: 5 }) {
          Select(this.groups.map(group => ({ value: group.name } as SelectOption)))
            .value(row.group).width('100%').enabled(!this.busy && this.selectionGroup.length === 0)
            .fontColor($r('app.color.main_text')).backgroundColor($r('app.color.field'))
            .border({ width: 1, color: $r('app.color.outline') })
            .onSelect(index => { this.changeCategory(row.uri, row.group, this.groups[index].name); })
          this.photoHint(row)
        }
        .layoutWeight(1)
      }
      .width('100%').constraintSize({ minHeight: 88 }).padding(10).borderRadius(18)
      .backgroundColor($r('app.color.panel')).border({ width: 1, color: $r('app.color.outline') })
      .opacity(this.movingUri === row.uri ? 0 : 1)
      .translate({ x: this.movingUri === row.uri ? -12 : 0 })
    }
  }

  @Builder
  controls() {
      Column({ space: 12 }) {
        Row({ space: 14 }) {
          Column({ space: 5 }) {
            Text('照片归类').fontSize(28).fontWeight(FontWeight.Bold).fontColor($r('app.color.main_text'))
            Text(this.selectedUris.length === 0 ? '选好照片，一次离线归类' : '本批 ' + this.selectedUris.length + ' 张')
              .fontSize(14).fontColor($r('app.color.secondary_text'))
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          Image($r('app.media.photosort_icon'))
            .width(this.groups.length === 0 ? 72 : 58).aspectRatio(1).borderRadius(20).draggable(false)
            .border({ width: 2, color: $r('app.color.panel') }).accessibilityLevel('no')
        }
        .width('100%').padding(16).borderRadius(22).backgroundColor($r('app.color.summary'))
        .border({ width: 1, color: $r('app.color.outline') })
        Column({ space: 8 }) {
          Text(this.classifying ? '正在离线分类 · ' + this.progressDone + ' / ' + this.selectedUris.length : this.status)
            .fontSize(15).fontColor($r('app.color.main_text')).width('100%')
          if (this.classifying) {
            Progress({ value: this.progressDone, total: this.selectedUris.length, type: ProgressType.Linear })
              .width('100%').color($r('app.color.accent'))
          }
        }
        .width('100%').padding(15).backgroundColor($r('app.color.summary')).borderRadius(16)
        if (this.smokeStatus.length > 0) {
          Text(this.smokeStatus).fontSize(14).fontColor($r('app.color.secondary_text'))
        }
        Button(this.selectedUris.length === 0 ? '从系统图库选图' : '重新选图')
          .enabled(!this.busy).width('100%').backgroundColor($r('app.color.accent'))
          .fontColor($r('app.color.on_accent'))
          .onClick(() => { this.choosePhotos(); })
        Button('隐私说明', { type: ButtonType.Normal }).height(40).backgroundColor(Color.Transparent)
          .fontColor($r('app.color.main_text')).onClick(() => {
            this.getUIContext().showAlertDialog({
              title: '隐私说明',
              message: '应用对你通过系统选图器选中的照片进行离线分类，照片和识别文字不会上传。读取已有相册需要图库读权限，归档到指定相册和删除原图需要图库写权限。当前分类结果保存在内存中，应用退出后清除。',
              confirm: { value: '关闭', action: () => {} }
            });
          })
        if (this.selectedUris.length > 0) {
          Column({ space: 10 }) {
            if (this.groups.length === 0 && this.selectedUris.length < BATCH_LIMIT) {
              Button('追加照片 · 已选 ' + this.selectedUris.length + ' / ' + BATCH_LIMIT)
                .enabled(!this.busy).width('100%').backgroundColor($r('app.color.summary'))
                .fontColor($r('app.color.main_text')).onClick(() => { this.choosePhotos(true); })
            }
            Text('分类设置').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.main_text'))
            TextArea({ text: this.categoryInput, placeholder: '每行一个类别' })
              .constraintSize({ minHeight: 128 }).enabled(!this.busy).maxLength(600)
              .fontColor($r('app.color.main_text')).backgroundColor($r('app.color.field'))
              .border({ width: 1, color: $r('app.color.outline') }).borderRadius(14)
              .onChange(value => { this.categoryInput = value; })
            Text('每行一类。可加说明，如「知识：数学题」。')
              .fontSize(13).fontColor($r('app.color.secondary_text'))
            Button('开始离线分类').enabled(!this.busy).width('100%').backgroundColor($r('app.color.accent'))
              .fontColor($r('app.color.on_accent')).onClick(() => { this.classify(); })
          }
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 8 })))
          .padding(14).width('100%').alignItems(HorizontalAlign.Start)
          .borderRadius(18).backgroundColor($r('app.color.panel'))
          .border({ width: 1, color: $r('app.color.outline') })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 20, bottom: 6 }).width('100%')
  }

  @Builder
  archivePicker() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Image($r('app.media.photosort_icon')).width(50).height(50).borderRadius(14).draggable(false)
          .accessibilityLevel('no')
        Column({ space: 4 }) {
          Text(this.archiveGroup.length > 0 ? '整组归档' : '归档已选').fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.main_text')).width('100%')
          Text((this.archiveGroup.length > 0 ? this.archiveGroup : this.selectionGroup) + ' · ' +
            this.archiveUris().length + ' 张照片').fontSize(14).fontColor($r('app.color.secondary_text')).width('100%')
        }
        .layoutWeight(1)
      }
      .width('100%').padding(12).borderRadius(16).backgroundColor($r('app.color.summary'))
      if (this.albumNames.length > 0) {
        Select(this.albumNames.map(name => ({ value: name } as SelectOption)))
          .selected(this.albumIndex(this.archiveGroup || this.selectionGroup))
          .value(this.selectedAlbumName(this.archiveGroup || this.selectionGroup)).width('100%').enabled(!this.busy)
          .onSelect(index => { this.setAlbumTarget(this.archiveGroup || this.selectionGroup, index); })
        Button('归档到目标相册').width('100%').height(48)
          .enabled(!this.busy && this.albumIndex(this.archiveGroup || this.selectionGroup) >= 0)
          .backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent'))
          .onClick(() => { void this.archiveToExisting(false); })
      } else {
        Button('读取已有相册').width('100%').height(44).enabled(!this.busy)
          .backgroundColor($r('app.color.summary')).fontColor($r('app.color.main_text'))
          .onClick(() => { void this.loadExistingAlbums(); })
      }
      Text('也可直接将副本保存到系统图库。')
        .fontSize(14).fontColor($r('app.color.secondary_text')).width('100%')
      if (this.archiveUris().length === 1) {
        SaveButton({ text: SaveDescription.SAVE_IMAGE, buttonType: ButtonType.Capsule })
          .width('100%').height(48)
          .onClick((_event: ClickEvent, result: SaveButtonOnClickResult) => {
            if (result === SaveButtonOnClickResult.SUCCESS) {
              void this.archiveSelection(true);
            } else {
              this.showFeedback('未获得系统保存授权。');
            }
          })
      } else {
        Button('批量保存 ' + Math.min(this.archiveUris().length, EXPORT_LIMIT) + ' 张')
          .enabled(!this.busy && this.archiveUris().length > 0)
          .width('100%').height(48).backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent'))
          .onClick(() => { void this.archiveSelection(false); })
      }
    }
    .width('100%').padding({ top: 14, bottom: 18, left: 20, right: 20 })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        List({ space: 8, scroller: this.listScroller }) {
          ListItem() { this.controls() }
          LazyForEach(this.rows, (row: PhotoRow) => {
            ListItem() {
              if (row.uri.length === 0) {
                this.groupHeader(row)
              } else {
                this.photoRow(row)
              }
            }
            .opacity(this.resultsVisible ? 1 : 0)
            .translate({ y: this.resultsVisible ? 0 : 10 })
          }, (row: PhotoRow) => row.key())
        }
        .cachedCount(6).layoutWeight(1)
        .padding({ left: 16, right: 16, bottom: 12 }).constraintSize({ maxWidth: 720 }).width('100%')
        .bindContentCover(this.previewVisible, this.photoPreview(), {
          modalTransition: ModalTransition.ALPHA,
          onDisappear: () => {
            this.previewVisible = false;
            this.previewTotal = 0;
            this.previewRows.update([]);
          }
        })
        if (this.selectionGroup.length > 0) {
          Row({ space: 12 }) {
            Button('取消').enabled(!this.busy).backgroundColor($r('app.color.summary'))
              .fontColor($r('app.color.main_text')).onClick(() => { this.clearSelection(); })
            Button('归档已选 · ' + this.checkedUris.length).layoutWeight(1)
              .enabled(!this.busy && this.checkedUris.length > 0).backgroundColor($r('app.color.accent'))
              .fontColor($r('app.color.on_accent')).onClick(() => { this.openArchivePicker(); })
          }
          .width('100%').constraintSize({ maxWidth: 720 }).padding({ left: 16, right: 16, top: 10, bottom: 8 })
          .backgroundColor($r('app.color.panel'))
          .border({ width: { top: 1 }, color: $r('app.color.outline') })
        } else if (this.trashCount() > 0 || this.groups.some(group => group.uris.length > 0)) {
          Column({ space: 8 }) {
            if (this.groups.some(group => group.name !== TRASH_CATEGORY && group.uris.length > 0)) {
              Row({ space: 8 }) {
                Button(this.albumNames.length > 0 ? '刷新相册' : '读取已有相册').height(44).layoutWeight(1)
                  .enabled(!this.busy).backgroundColor($r('app.color.summary')).fontColor($r('app.color.main_text'))
                  .onClick(() => { void this.loadExistingAlbums(); })
                if (this.mappedCount() > 0) {
                  Button('批量归档 · ' + this.mappedCount()).height(44).layoutWeight(1)
                    .enabled(!this.busy).backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent'))
                    .onClick(() => { void this.archiveToExisting(true); })
                }
              }.width('100%')
            }
            if (this.needsTrashPermission) {
              Button('去系统授权').width('100%').height(44).enabled(!this.busy)
                .backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent'))
                .onClick(() => { void this.openTrashPermissionSettings(); })
            }
            if (this.trashCount() > 0) {
              Button('移到最近删除 · ' + this.trashCount()).width('100%').height(44).enabled(!this.busy)
                .backgroundColor($r('app.color.danger_surface')).fontColor($r('app.color.danger_text'))
                .onClick(() => { this.confirmTrash(); })
            }
          }
          .width('100%').constraintSize({ maxWidth: 720 }).padding({ left: 16, right: 16, top: 10, bottom: 8 })
          .backgroundColor($r('app.color.panel'))
          .border({ width: { top: 1 }, color: $r('app.color.outline') })
        }
    }
    .width('100%').height('100%').backgroundColor($r('app.color.canvas'))
    if (this.feedback.length > 0) {
      Row({ space: 9 }) {
        Image($r('app.media.photosort_icon')).width(26).height(26).borderRadius(8).draggable(false)
          .accessibilityLevel('no')
        Text(this.feedback).fontSize(14).fontColor($r('app.color.on_accent')).maxLines(3)
      }
      .padding({ left: 17, right: 17, top: 12, bottom: 12 }).borderRadius(18)
      .constraintSize({ maxWidth: '88%' }).margin({ bottom: 74 }).backgroundColor($r('app.color.accent'))
      .hitTestBehavior(HitTestMode.None)
      .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 12 })))
    }
    }
    .width('100%').height('100%')
    .bindSheet(this.albumSheetVisible, this.archivePicker(), {
      height: SheetSize.FIT_CONTENT,
      backgroundColor: $r('app.color.panel'),
      onDisappear: () => { this.albumSheetVisible = false; }
    })
  }
}
