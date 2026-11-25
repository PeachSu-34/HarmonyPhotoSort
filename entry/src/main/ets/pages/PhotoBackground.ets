import { backgroundTaskManager } from '@kit.BackgroundTasksKit';

export class PhotoBackground {
  private static active: boolean = false;
  private static requestId: number = -1;

  static begin(): void {
    PhotoBackground.active = true;
  }

  static enterBackground(): void {
    if (!PhotoBackground.active || PhotoBackground.requestId >= 0) {
      return;
    }
    try {
      const delay = backgroundTaskManager.requestSuspendDelay('正在离线归类用户选中的照片', () => {
        PhotoBackground.releaseDelay();
      });
      PhotoBackground.requestId = delay.requestId;
    } catch (_error) {
      // The system can deny a delay. The in-memory batch continues when the ability is resumed.
    }
  }

  static releaseDelay(): void {
    const requestId = PhotoBackground.requestId;
    PhotoBackground.requestId = -1;
    if (requestId >= 0) {
      try {
        backgroundTaskManager.cancelSuspendDelay(requestId);
      } catch (_error) {
        // The request may already have expired.
      }
    }
  }

  static finish(): void {
    PhotoBackground.active = false;
    PhotoBackground.releaseDelay();
  }
}
