/**
 * 尼康 BLE 的两个定长载荷：校时（0x2006）与定位（0x2007）。
 *
 * 字节布局来自 ZPill 的真机定案（`time_payload.dart` / `geo_payload.dart`），
 * 并与 SnapBridge smali、nsg 双源交叉验证过。
 */

/** 一次定位快照。 */
export interface BleGeoFix {
  latitude: number;
  longitude: number;
  altitude: number;
  satellites: number;
  utc: Date;
}

/** 0x2006 CURRENT_TIME：10 字节小端。 */
export class BleTimePayload {
  /**
   * @param now 取它的 UTC 字段
   * @param offsetMinutes 时区偏移，东半球为正（UTC+8 → 480）
   */
  static build(now: Date, offsetMinutes: number): Uint8Array {
    const out = new Uint8Array(10);
    const view = new DataView(out.buffer);
    view.setUint16(0, now.getUTCFullYear(), true);
    view.setUint8(2, now.getUTCMonth() + 1);
    view.setUint8(3, now.getUTCDate());
    view.setUint8(4, now.getUTCHours());
    view.setUint8(5, now.getUTCMinutes());
    view.setUint8(6, now.getUTCSeconds());
    view.setUint8(7, 0);
    // 截断而非 floor：UTC-3:30 必须是 (-3, -30)，floor 会变成 (-4, +30)。
    const hours = Math.trunc(offsetMinutes / 60);
    const minutes = offsetMinutes % 60;
    view.setInt8(8, hours);
    view.setInt8(9, minutes);
    return out;
  }

  /**
   * 把相机读回来的 0x2006 解成可读文本（诊断用）。
   *
   * 相机自己只回 7 字节（年 2 + 月日时分秒），不带时区，所以这里也按 7 字节读，
   * 多出来的字节忽略。时间字段是 UTC。
   */
  static describe(value: Uint8Array): string {
    if (value.length < 7) return `${value.length}B（格式不符）`;
    const view = new DataView(value.buffer, value.byteOffset, value.byteLength);
    const year = view.getUint16(0, true);
    const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    let text = `${year}-${pad(value[2])}-${pad(value[3])}`
      + ` ${pad(value[4])}:${pad(value[5])}:${pad(value[6])} UTC`;
    // 和本机现在差多少：一眼看出「相机到底收没收到我写的时间」。
    const camMs = Date.UTC(year, value[2] - 1, value[3], value[4], value[5], value[6]);
    const diff = Math.round((camMs - Date.now()) / 1000);
    if (Math.abs(diff) > 5) {
      text += `（与本机差 ${diff > 0 ? '+' : ''}${diff} 秒）`;
    } else {
      text += '（与本机一致）';
    }
    return text;
  }
}

/** 0x2007 LOCATION_INFORMATION：41 字节小端。 */
export class BleGeoPayload {
  static readonly LENGTH: number = 41;
  private static readonly HEADER: number = 0x007F;
  private static readonly VALID_OFFSET: number = 24;
  private static readonly VALID: number = 0x01;

  /**
   * 「位置已失效」：只有头 + valid=0，其余全 0。
   *
   * 相机收到 valid=0 会丢掉保存的位置，之后拍的照片不再带 GPS。**只能发一次**——
   * 连发多条 valid=0 相机会拒收（实测结论，见 1.66.17 的 SERVICES.md）。
   */
  static buildInvalid(): Uint8Array {
    const out = new Uint8Array(BleGeoPayload.LENGTH);
    const view = new DataView(out.buffer);
    view.setUint16(0, BleGeoPayload.HEADER, true);
    out[BleGeoPayload.VALID_OFFSET] = 0;
    return out;
  }

  static build(fix: BleGeoFix): Uint8Array {
    const out = new Uint8Array(BleGeoPayload.LENGTH);
    const view = new DataView(out.buffer);
    let off = 0;
    view.setUint16(off, BleGeoPayload.HEADER, true);
    off += 2;

    const lat = BleGeoPayload.decimalToNikon(fix.latitude, 0x4E, 0x53); // N/S
    for (const b of lat) out[off++] = b;

    const lon = BleGeoPayload.decimalToNikon(fix.longitude, 0x45, 0x57); // E/W
    for (const b of lon) out[off++] = b;

    out[off++] = Math.max(0, Math.min(100, Math.trunc(fix.satellites)));

    const above = fix.altitude >= 0;
    out[off++] = above ? 0x50 : 0x4D; // 'P' / 'M'
    view.setUint16(off, Math.abs(Math.trunc(fix.altitude)) & 0xFFFF, true);
    off += 2;

    const t = fix.utc;
    view.setUint16(off, t.getUTCFullYear(), true);
    off += 2;
    out[off++] = t.getUTCMonth() + 1;
    out[off++] = t.getUTCDate();
    out[off++] = t.getUTCHours();
    out[off++] = t.getUTCMinutes();
    out[off++] = t.getUTCSeconds();
    out[off++] = Math.trunc(t.getUTCMilliseconds() / 10);

    out[off++] = BleGeoPayload.VALID;
    // "WGS-84"
    const wgs = [0x57, 0x47, 0x53, 0x2D, 0x38, 0x34];
    for (const c of wgs) out[off++] = c;
    while (off < BleGeoPayload.LENGTH) out[off++] = 0;
    return out;
  }

  /** 十进制度 → (方向, 度, 分, submin1, submin2)。 */
  private static decimalToNikon(decimal: number, positiveRef: number,
                                negativeRef: number): number[] {
    const direction = decimal < 0 ? negativeRef : positiveRef;
    const abs = Math.abs(decimal);
    const degrees = Math.floor(abs);
    const minutesFull = (abs - degrees) * 60.0;
    const minutes = Math.floor(minutesFull);
    const submin1Full = (minutesFull - minutes) * 100.0;
    const submin1 = Math.floor(submin1Full);
    const submin2Full = (submin1Full - submin1) * 100.0;
    const submin2 = Math.floor(submin2Full);
    return [direction, degrees, minutes, submin1, submin2];
  }
}
