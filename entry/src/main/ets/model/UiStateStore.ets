import { PersistenceV2 } from '@kit.ArkUI';

/**
 * 界面交互状态。
 *
 * 单独一个 key，不要把这些字段追加到已有的 `SettingsStore`：
 * `PersistenceV2` 恢复旧数据时不会给已有对象补上新增的 `@Trace` 字段，
 * 直接往旧类里加字段会导致新字段既不恢复也不落盘。
 */
@ObservedV2
export class UiStateStore {
  static readonly KEY = 'ui_state';

  /** 上次停留的标签页：0 画廊 / 1 相机 / 2 设置。 */
  @Trace lastTab: number = 1;
  /** 上次使用的画廊格式筛选，'' 表示全部。 */
  @Trace galleryFilter: string = '';
  /** 上次识别到的握持手，系统未上报时作为浮岛位置的兜底。 */
  @Trace lastHandedness: boolean = false;

  private static instance_: UiStateStore;

  static getInstance(): UiStateStore {
    if (!UiStateStore.instance_) {
      UiStateStore.instance_ = PersistenceV2.globalConnect({
        type: UiStateStore,
        key: UiStateStore.KEY,
        defaultCreator: () => new UiStateStore()
      })!;
    }
    return UiStateStore.instance_;
  }
}
