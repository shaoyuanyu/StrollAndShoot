import { PersistenceV2 } from '@kit.ArkUI';

/**
 * 本地收藏（以「相机身份 + 文件名 + 大小」为键）。
 *
 * 单独一个 `PersistenceV2` key，不要挂到 `SettingsStore` 上：后者恢复旧对象时
 * 不会补上新增的 `@Trace` 字段，收藏会既不恢复也不落盘。
 *
 * 键与下载记录的键同源（`CameraService.makeDownloadKey`），所以相机重连、
 * 文件改名（大小也会变）都不会把收藏错配到别的照片上。
 */
@ObservedV2
export class FavoritesStore {
  static readonly KEY = 'photo_favorites';

  /** 收藏键列表。整体替换而不是原地 push，V2 才能追踪到变化。 */
  @Trace keys: string[] = [];

  private static instance_: FavoritesStore;

  static getInstance(): FavoritesStore {
    if (!FavoritesStore.instance_) {
      FavoritesStore.instance_ = PersistenceV2.globalConnect({
        type: FavoritesStore,
        key: FavoritesStore.KEY,
        defaultCreator: () => new FavoritesStore()
      })!;
    }
    return FavoritesStore.instance_;
  }

  isFavorite(key: string): boolean {
    return this.keys.indexOf(key) >= 0;
  }

  /** 切换收藏状态，返回切换后的状态（true = 已收藏）。 */
  toggle(key: string): boolean {
    const idx = this.keys.indexOf(key);
    if (idx >= 0) {
      const next = this.keys.slice();
      next.splice(idx, 1);
      this.keys = next;
      return false;
    }
    this.keys = this.keys.concat([key]);
    return true;
  }
}
