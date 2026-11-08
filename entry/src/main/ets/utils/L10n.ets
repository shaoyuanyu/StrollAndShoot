/**
 * 运行时字符串本地化。
 *
 * UI 里的静态文案直接用 `$r('app.string.*')`，声明式框架会按当前区域解析；
 * 但状态文案、错误原因、格式化单位这类在 service / utils 里拼出来的字符串
 * 拿不到 `$r` 的格式化结果，需要在运行时按资源名取字符串。
 *
 * 资源管理器在 EntryAbility.onCreate（或 Index.aboutToAppear）注入一次即可。
 * 这里用 type-only import，避免 utils 依赖 Localization Kit 的运行时模块，
 * GpsFormat 之类的纯逻辑仍能在 Local Test 里跑（测试改注入 resolver）。
 */

import type { resourceManager } from '@kit.LocalizationKit';

export type L10nStringResolver = (name: string, args: Array<string | number>) => string;
export type L10nPluralResolver = (name: string, count: number,
  args: Array<string | number>) => string;

export class L10n {
  private static manager: resourceManager.ResourceManager | null = null;
  private static stringResolver: L10nStringResolver | null = null;
  private static pluralResolver: L10nPluralResolver | null = null;

  /** 注入资源管理器。重复调用以最后一次为准（Ability 重建时会重新注入）。 */
  static init(manager: resourceManager.ResourceManager): void {
    L10n.manager = manager;
  }

  /** 测试或预览环境可以注入自己的实现；传 null 恢复未初始化状态。 */
  static setResolvers(stringResolver: L10nStringResolver | null,
    pluralResolver: L10nPluralResolver | null): void {
    L10n.stringResolver = stringResolver;
    L10n.pluralResolver = pluralResolver;
  }

  static isReady(): boolean {
    return L10n.manager !== null || L10n.stringResolver !== null;
  }

  /** 按资源名取字符串并替换 `%1$s` / `%2$d` 这类占位符。 */
  static tr(name: string, ...args: Array<string | number>): string {
    const manager = L10n.manager;
    if (manager !== null) {
      try {
        return manager.getStringByNameSync(name, ...args);
      } catch (_e) {
        return name;
      }
    }
    if (L10n.stringResolver !== null) return L10n.stringResolver(name, args);
    return name;
  }

  /** 取复数资源。count 既用于选择单复数，也通常作为第一个占位符传入。 */
  static plural(name: string, count: number, ...args: Array<string | number>): string {
    const manager = L10n.manager;
    if (manager !== null) {
      try {
        return manager.getIntPluralStringByNameSync(name, count, ...args);
      } catch (_e) {
        return name;
      }
    }
    if (L10n.pluralResolver !== null) return L10n.pluralResolver(name, count, args);
    return name;
  }
}
