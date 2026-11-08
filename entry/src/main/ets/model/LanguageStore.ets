import { PersistenceV2 } from '@kit.ArkUI';

/**
 * 应用语言偏好。
 *
 * 单独一个 key，不要追加到 `SettingsStore`：`PersistenceV2` 恢复旧对象时
 * 不会补上新增的 `@Trace` 字段，直接往旧类里加字段会导致新字段既不恢复也不落盘。
 *
 * 取值：
 * - `system`：跟随系统（默认）
 * - `zh-Hans`：简体中文
 * - `zh-Hant`：繁体中文
 * - `en`：英文
 */
@ObservedV2
export class LanguageStore {
  static readonly KEY = 'language_state';

  @Trace appLanguage: string = 'system';

  private static instance_: LanguageStore;

  static getInstance(): LanguageStore {
    if (!LanguageStore.instance_) {
      LanguageStore.instance_ = PersistenceV2.globalConnect({
        type: LanguageStore,
        key: LanguageStore.KEY,
        defaultCreator: () => new LanguageStore()
      })!;
    }
    return LanguageStore.instance_;
  }
}
