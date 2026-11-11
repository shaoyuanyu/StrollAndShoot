/**
 * 相机立牌（商品图）按型号匹配。
 *
 * 图片取自尼康中国官网 Z 系列产品页的产品图，裁掉多余留白、转成带透明通道的
 * WebP（10 个型号合计约 460 KB）。目前只做尼康 Z 系列，认不出来的机型不渲染
 * 立牌，页面照常工作。
 *
 * **型号串有两套口径**，匹配时都要认：
 * - PTP `DeviceInfo.model` 是尼康内部名 —— 实测 Z 50II 返回 `Z50_2`；
 * - USB 的 iProduct 与界面文案用营销名 —— `Z 50II`。
 *
 * 所以先去掉空格、下划线、连字符，再按「越具体越先」的顺序比对。
 */

interface StandeeEntry {
  /** 归一化后的候选子串（大写、无分隔符）。 */
  needles: string[];
  key: string;
}

/**
 * 顺序不能改：长串必须排在它的前缀前面。
 *
 * - `Z5IIC` 含 `Z5II`、`Z6III` 含 `Z6II` → 长的先匹配；
 * - `Z50_2`（→ `Z502`）与 `Z5_2`（→ `Z52`）互不包含，但都排在 `Z5II` 前面，
 *   避免任何前缀误命中。
 */
const ENTRIES: StandeeEntry[] = [
  { needles: ['Z5IIC', 'Z52C'], key: 'z5iic' },
  { needles: ['Z6III', 'Z63'], key: 'z6iii' },
  { needles: ['Z50II', 'Z502'], key: 'z50ii' },
  { needles: ['Z5II', 'Z52'], key: 'z5ii' },
  { needles: ['Z6II', 'Z62'], key: 'z6ii' },
  { needles: ['Z7II', 'Z72'], key: 'z7ii' },
  { needles: ['Z9'], key: 'z9' },
  { needles: ['Z8'], key: 'z8' },
  { needles: ['ZF'], key: 'zf' },
  { needles: ['Z30'], key: 'z30' }
];

function normalize(raw: string): string {
  return raw.toUpperCase().replace(/[\s_\-]/g, '');
}

/**
 * 型号串 → 立牌 key；认不出来返回 `''`。
 *
 * 只在带立牌的机型上返回非空，因此 `CameraModelStore` 里存的 key 一定合法。
 */
export function cameraStandeeKey(raw: string): string {
  const s = normalize(raw);
  if (s === '') return '';
  // Z fc 没有透明底的产品图，别让它落到 Z f 上
  if (s.includes('ZFC')) return '';
  for (const entry of ENTRIES) {
    for (const needle of entry.needles) {
      if (s.includes(needle)) return entry.key;
    }
  }
  return '';
}

/**
 * key → 立牌资源。
 *
 * key 只可能来自 `cameraStandeeKey()`，所以 switch 是穷尽的；兜底分支不可达，
 * 保留它是为了返回类型能是非空 `Resource`（`Image` 不接受 undefined）。
 */
export function cameraStandeeMedia(key: string): Resource {
  switch (key) {
    case 'z9': return $r('app.media.camera_z9');
    case 'z8': return $r('app.media.camera_z8');
    case 'z7ii': return $r('app.media.camera_z7ii');
    case 'z6iii': return $r('app.media.camera_z6iii');
    case 'z6ii': return $r('app.media.camera_z6ii');
    case 'z5ii': return $r('app.media.camera_z5ii');
    case 'z5iic': return $r('app.media.camera_z5iic');
    case 'zf': return $r('app.media.camera_zf');
    case 'z50ii': return $r('app.media.camera_z50ii');
    case 'z30': return $r('app.media.camera_z30');
    default: return $r('app.media.camera_z9');
  }
}

/** key → 展示用的官方型号名（尼康的写法带空格：Z 50II、Z f）。 */
export function cameraStandeeLabel(key: string): string {
  switch (key) {
    case 'z9': return 'Z 9';
    case 'z8': return 'Z 8';
    case 'z7ii': return 'Z 7II';
    case 'z6iii': return 'Z 6III';
    case 'z6ii': return 'Z 6II';
    case 'z5ii': return 'Z 5II';
    case 'z5iic': return 'Z 5IIC';
    case 'zf': return 'Z f';
    case 'z50ii': return 'Z 50II';
    case 'z30': return 'Z 30';
    default: return '';
  }
}

/**
 * 从 BLE 广播名里取序列号尾段：`Z50_2_8079350` → `8079350`。
 *
 * 这个数与相机菜单、官方 SnapBridge 显示的「序列号」一致；而 BLE stage4 给出的
 * 是另一串（本机实测 `1246090`），不要混用。
 */
export function cameraSerialFromBleName(name: string): string {
  const parts = name.split('_');
  if (parts.length < 2) return '';
  const tail = parts[parts.length - 1].trim();
  return /^[0-9]+$/.test(tail) ? tail.replace(/^0+/, '') : '';
}
