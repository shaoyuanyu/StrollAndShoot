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

/**
 * 所有带立牌的机型 key，按「旗舰 → 入门」排。
 *
 * 只给「调试包里的模拟型号下拉」用：下拉项由 `cameraStandeeLabel(key)` 生成，
 * 因此下拉里每一款都必然有立牌，选完接上模拟相机就能看到对应机型的效果。
 * **顺序与匹配用的 `ENTRIES` 无关**，不要拿它做匹配。
 */
export function cameraStandeeKeys(): string[] {
  return ['z9', 'z8', 'z7ii', 'z6iii', 'z6ii', 'z5ii', 'z5iic', 'zf', 'z50ii', 'z30'];
}

/**
 * key → 素材的宽高比（画布像素宽 / 高）。
 *
 * 立牌的**盒子必须和素材同一个宽高比**。`Image` 的 `Contain` 是把整张画布居中塞进
 * 盒子里：盒子比画布「更高」时，上下各会留一条透明带，立牌底边和倒影顶边之间就
 * 多出两倍透明带 → 肉眼一条白缝。1.46.0 就踩了这条：卡片宽度只有 333.7vp，
 * 172vp 高对应的宽度是 347vp，画布改按宽度顶满、上下各留 3.3vp。
 *
 * 所以盒子的宽由「高度 × 这个比例」算出来（见 `CameraPage.standeeWidth()`），
 * 不写死。**重新生成 webp 必须同步这张表**，否则缝隙会回来。
 */
export function cameraStandeeAspect(key: string): number {
  switch (key) {
    case 'z9': return 703 / 429;
    case 'z8': return 729 / 371;
    case 'z7ii': return 742 / 363;
    case 'z6iii': return 753 / 361;
    case 'z6ii': return 742 / 363;
    case 'z5ii': return 756 / 365;
    case 'z5iic': return 743 / 322;
    case 'zf': return 715 / 354;
    case 'z50ii': return 722 / 358;
    case 'z30': return 702 / 284;
    default: return 703 / 429;
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
