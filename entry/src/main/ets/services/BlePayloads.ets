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
}

/** 0x2007 LOCATION_INFORMATION：41 字节小端。 */
export class BleGeoPayload {
  static readonly LENGTH: number = 41;
  private static readonly HEADER: number = 0x007F;
  private static readonly VALID: number = 0x01;

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
