/**
 * 磨砂玻璃（沉浸光感）效果的调试开关。
 *
 * 背景：模拟器（Mate 80 / HarmonyOS 7.0.0）的 GPU 不支持磨砂玻璃着色器，
 * `hilog` 里会持续打 `GEXFrostedGlassBlurShaderFilter::IsFilterSupported is false`，
 * 一旦页面上叠了材质并持续重绘，渲染器就会退化成大片多边形色块，截图无法用于
 * 视觉验收。真机没有这个问题。
 *
 * 设置页「调试」里可以打开「关闭磨砂玻璃」，本工具类负责在所有材质 / 模糊的
 * 调用点把效果换成官方提供的空材质或 0 模糊：
 *   - `.systemMaterial(GlassEffect.material(m))` —— 关闭时返回 `uiMaterial.Material.empty`
 *     （官方 API：用于关闭单个组件的沉浸光感，不需要删掉整条属性链）；
 *   - `.backgroundBlurStyle(GlassEffect.blurStyle(style))` —— 关闭时返回 `BlurStyle.NONE`；
 *   - `.linearGradientBlur(GlassEffect.blurRadius(96), ...)` —— 关闭时返回 0。
 *
 * release 包恒为开启：设置项只在调试包里渲染，且这里再用 `isDebugBuild()` 兜底，
 * 避免调试包留下的持久化开关影响发布包观感。
 */
import { uiMaterial } from '@kit.ArkUI';
import { SettingsStore } from '../model/SettingsStore';
import { MockPtpDevice } from '../debug/MockPtpDevice';

export class GlassEffect {
  /** 是否保留磨砂玻璃效果。debug 包里受设置项控制，release 包恒为 true。 */
  static isEnabled(): boolean {
    if (!MockPtpDevice.isDebugBuild()) {
      return true;
    }
    try {
      return !SettingsStore.getInstance().debugDisableGlass;
    } catch (_e) {
      // PersistenceV2 尚未就绪时按开启处理
      return true;
    }
  }

  /** 组件材质：关闭时用官方的空材质，保留组件自身的 backgroundColor。 */
  static material(material: uiMaterial.Material): uiMaterial.Material {
    return GlassEffect.isEnabled() ? material : uiMaterial.Material.empty;
  }

  /** `backgroundBlurStyle` 的兜底。 */
  static blurStyle(style: BlurStyle): BlurStyle {
    return GlassEffect.isEnabled() ? style : BlurStyle.NONE;
  }

  /** `linearGradientBlur` 的模糊半径。 */
  static blurRadius(radius: number): number {
    return GlassEffect.isEnabled() ? radius : 0;
  }
}
