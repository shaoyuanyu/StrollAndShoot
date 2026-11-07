import { bundleManager } from '@kit.AbilityKit';

/**
 * 地图可用性的轻量判断。
 *
 * 模拟器只接受未签名 HAP，未签名包没有 Profile 里的
 * `com.huawei.service.mapkit` 能力，Map Kit 虽然能初始化，但瓦片请求会
 * 返回 403（`queryTile error: no map permission!`），页面只剩一块灰底。
 * 这里用签名指纹判断：没有签名的包直接走轨迹示意图，避免展开后看到空白。
 *
 * 真机安装 signed HAP 时 Profile 已带地图能力，指纹非空，正常加载地图。
 */
export class MapCapability {
  private static signed: boolean | null = null;

  static isSignedPackage(): boolean {
    if (MapCapability.signed !== null) return MapCapability.signed;
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_SIGNATURE_INFO
      );
      const sig = info.signatureInfo;
      MapCapability.signed = sig !== undefined && sig.fingerprint !== '';
    } catch (_e) {
      MapCapability.signed = false;
    }
    return MapCapability.signed === true;
  }
}
