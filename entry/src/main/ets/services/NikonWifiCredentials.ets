import { NikonBlowfish } from './NikonBlowfish';
import { NIKON_SALTS } from './NikonPairing';

/**
 * 尼康 `0x2004 CONNECTION_CONFIGURATION`（相机热点 Wi-Fi 凭据）解密。
 *
 * blob 是 **97B 或 102B** 的密文，布局：
 * `32B 加密 SSID + 64B 加密密码 + 1B 安全模式`（97B，SnapBridge 口径），
 * 或者在前面多一个 flag 字节、安全字节后多一段 LSS 尾（102B，LSS 口径，
 * flag bit0 = WiFi 块、bit1 = 蓝牙块，bit1 置位时尾部还有 4B
 * `sppMaxDataLength` —— 本项目真机读到 492）。
 *
 * 解密有两条路线（与 ZPill `wifi_credentials.dart` 一致）：
 *
 * 1. **LSS 会话密钥派生**（主路）：把握手材料按 libLsSec 的形态拼成
 *    `ctx = idx‖N_A[1..3]‖X[0..3]`，`K = MAC8(key1‖key2‖ctx)`（MAC 用与
 *    握手同一个定键 CBC-MAC），再把 K 当标准 Blowfish 密钥编排，字段各自
 *    CBC、IV 全零解密。ctx 的字节序与 key1 语义在还原报告里没定死，所以
 *    留几组候选，由**可打印性 oracle** 裁决 —— 全试不中就如实返回 null，
 *    绝不臆造明文。
 * 2. **定键试探**（兜底）：直接拿握手定键 ECB / CBC 试解 97B 布局。
 *
 * 用途：AP 模式（手机连相机热点）需要它；STA 模式虽然用不上凭据，但它同时
 * 是「相机到底认不认这次配对」的唯一硬指标 —— 相机不认，这个特征读出来
 * 是空的或者解不开。
 */

/** 解 0x2004 需要的握手材料。字段一律**线上原样字节序**。 */
export interface LssHandshakeMaterial {
  /** stage4 帧字节 9..17（相机序列号 ASCII + NUL）。 */
  key1: Uint8Array;
  /** stage1 帧字节 9..17（device + nonce，我方身份）。 */
  key2: Uint8Array;
  /** stage2 命中的 salt 序号（0–7），ctx 的 idx 位。 */
  saltIndex: number;
  /** stage2 帧字节 1..9（相机 nonce，报告记 N_A）。 */
  cameraNonce: Uint8Array;
  /** stage1 帧字节 1..9（手机 nonce，报告记 X）。 */
  phoneNonce: Uint8Array;
}

/** 解出来的相机热点凭据。 */
export interface WifiCredentials {
  ssid: string;
  password: string;
  /** 原始安全模式字节：0x00 开放 / 0x01 WPA2 / 0x02 WPA3 / 0x03 WPA2+WPA3。 */
  security: number;
  /** 命中的候选标识，只用于日志诊断。 */
  keySource: string;
  /** 安全模式的中文标签。 */
  securityLabel: string;
}

interface BlobLayout {
  name: string;
  ssidOff: number;
  pwOff: number;
  secOff: number;
}

interface KeyCandidate {
  tag: string;
  key: number[];
}

/** 握手定键（与 `NikonBlowfish` 里的一致，兜底路径用）。 */
const NIKON_FIXED_KEY: number[] = [0xFF, 0xFF, 0xAA, 0x55, 0x11, 0x22, 0x33, 0x00];

function be32(v: number): number[] {
  return [(v >>> 24) & 0xFF, (v >>> 16) & 0xFF, (v >>> 8) & 0xFF, v & 0xFF];
}

/** 从字节数组取一个大端 u32（`hash` 的块装填口径）。 */
function u32At(b: number[], i: number): number {
  return (((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]) >>> 0);
}

function isEight(b: Uint8Array): boolean {
  return b.length === 8;
}

/**
 * 可打印性 oracle：全部字节 ∈ 可打印 ASCII ∪ 0x00，且 0 只作尾填充。
 *
 * 这是整个解密里唯一的「对错判据」——错误的密钥解出来几乎必然含控制字符，
 * 32/64 字节全落在 `0x20..0x7E` 且尾部连续 0 的概率可以忽略。
 */
export function isPaddedPrintable(bytes: Uint8Array, allowEmpty: boolean): boolean {
  let printable = 0;
  let seenZero = false;
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i];
    if (b === 0) {
      seenZero = true;
      continue;
    }
    if (seenZero) return false;
    if (b < 0x20 || b > 0x7E) return false;
    printable++;
  }
  return printable > 0 || allowEmpty;
}

function trimNul(bytes: Uint8Array): string {
  let end = bytes.length;
  while (end > 0 && bytes[end - 1] === 0) {
    end--;
  }
  let s = '';
  for (let i = 0; i < end; i++) {
    s += String.fromCharCode(bytes[i]);
  }
  return s;
}

/** 安全模式字节 → 中文标签（LSS 口径：0x00 开放，1..3 加密）。 */
export function securityLabel(security: number): string {
  if (security === 0x00) return '开放';
  if (security === 0x01) return 'WPA2';
  if (security === 0x02) return 'WPA3';
  if (security === 0x03) return 'WPA2+WPA3';
  if (security === 0xFF) return '未定义';
  return `未知(${security})`;
}

/** ctx 的摇摆位候选：`(标签, N_A 起点, X 起点)`。 */
interface CtxShape {
  tag: string;
  naOff: number;
  xOff: number;
}

const CTX_SHAPES: CtxShape[] = [
  { tag: 'na1-3,x0-3', naOff: 1, xOff: 0 },
  { tag: 'na0-2,x0-3', naOff: 0, xOff: 0 },
  { tag: 'na1-3,x4-7', naOff: 1, xOff: 4 },
  { tag: 'na0-2,x4-7', naOff: 0, xOff: 4 }
];

/**
 * 会话密钥候选序列（惰性算：命中就停，不必把 8 组都算出来）。
 *
 * `key1` 有两种口径：还原报告契约（stage4 原样）与报告的未解项
 * 「是否等于 salt」（Zf 对应形态）。两种都试。
 */
async function deriveSessionKey(blowfish: NikonBlowfish, key1: number[], key2: number[],
                                ctx: number[]): Promise<number[]> {
  const h = await blowfish.hash([
    u32At(key1, 0), u32At(key1, 4),
    u32At(key2, 0), u32At(key2, 4),
    u32At(ctx, 0), u32At(ctx, 4)
  ]);
  return be32(h[0]).concat(be32(h[1]));
}

function key1Variants(material: LssHandshakeMaterial): KeyCandidate[] {
  const out: KeyCandidate[] = [];
  out.push({ tag: 'k1=stage4', key: Array.from(material.key1) });
  const salt = NIKON_SALTS[material.saltIndex >= 0 && material.saltIndex < 8
    ? material.saltIndex : 0];
  out.push({ tag: 'k1=salt', key: be32(salt[0]).concat(be32(salt[1])) });
  return out;
}

function buildCtx(material: LssHandshakeMaterial, shape: CtxShape): number[] {
  const na = material.cameraNonce;
  const x = material.phoneNonce;
  return [
    material.saltIndex & 0xFF,
    na[shape.naOff], na[shape.naOff + 1], na[shape.naOff + 2],
    x[shape.xOff], x[shape.xOff + 1], x[shape.xOff + 2], x[shape.xOff + 3]
  ];
}

/**
 * 解 0x2004 凭据。
 *
 * @param blob 读到的原始密文（97B 或 102B）
 * @param lss 握手材料；为 null 时只走定键兜底
 * @returns 解出且通过 oracle 的凭据；全试未中返回 null（不猜）
 */
export async function decodeWifiCredentials(blob: Uint8Array, lss: LssHandshakeMaterial | null,
                                            onLog: (msg: string) => void): Promise<WifiCredentials | null> {
  if (blob.length < 97) {
    onLog(`0x2004: 长度 ${blob.length}B 不足 97B，不是凭据布局`);
    return null;
  }
  const layouts: BlobLayout[] = [{ name: 'l97', ssidOff: 0, pwOff: 32, secOff: 96 }];
  if (blob.length >= 98) {
    layouts.push({ name: 'l98', ssidOff: 1, pwOff: 33, secOff: 97 });
  }
  const blowfish = new NikonBlowfish(onLog);
  const materialOk = lss !== null && isEight(lss.key1) && isEight(lss.key2) &&
    isEight(lss.cameraNonce) && isEight(lss.phoneNonce);

  for (const layout of layouts) {
    const security = blob[layout.secOff];
    // LSS 口径定案是 0..3 + 0xFF；放宽到 0x04 留方言韧性，界外直接弃。
    if (security > 0x04 && security !== 0xFF) continue;
    const cipherSsid = blob.subarray(layout.ssidOff, layout.ssidOff + 32);
    const cipherPw = blob.subarray(layout.pwOff, layout.pwOff + 64);
    const allowEmptyPw = security === 0x00 || security === 0x01;

    if (materialOk && lss !== null) {
      const key1s = key1Variants(lss);
      for (const k1 of key1s) {
        for (const shape of CTX_SHAPES) {
          const ctx = buildCtx(lss, shape);
          let key: number[] = [];
          try {
            key = await deriveSessionKey(blowfish, k1.key, Array.from(lss.key2), ctx);
          } catch (err) {
            onLog(`0x2004: 会话密钥派生失败 ${(err as Error).message}`);
            continue;
          }
          const hit = await tryDecode(blowfish, key, cipherSsid, cipherPw, allowEmptyPw, true);
          if (hit !== null) {
            onLog(`0x2004: 解出凭据（lss-kdf ${k1.tag} ctx=${shape.tag} lay=${layout.name}）`);
            return {
              ssid: trimNul(hit[0]),
              password: trimNul(hit[1]),
              security: security,
              keySource: `lss-kdf ${k1.tag} ctx=${shape.tag} lay=${layout.name}`,
              securityLabel: securityLabel(security)
            };
          }
        }
      }
    }

    if (layout.name === 'l97') {
      // 兜底：定键直接试解（2026-10-13 口径）。ECB 在前，与上游顺序一致。
      const modes: string[] = ['ecb', 'cbc'];
      for (const mode of modes) {
        const hit = await tryDecode(blowfish, NIKON_FIXED_KEY, cipherSsid, cipherPw,
          allowEmptyPw, mode === 'cbc');
        if (hit !== null) {
          onLog(`0x2004: 解出凭据（定键 ${mode}）`);
          return {
            ssid: trimNul(hit[0]),
            password: trimNul(hit[1]),
            security: security,
            keySource: mode === 'cbc' ? 'fixed-nikon-key+cbc-iv0' : 'fixed-nikon-key+ecb',
            securityLabel: securityLabel(security)
          };
        }
      }
    }
  }
  onLog('0x2004: 所有候选均未通过可打印性校验');
  return null;
}

/** 试解一对字段；通过 oracle 返回 `[ssidBytes, passwordBytes]`，否则 null。 */
async function tryDecode(blowfish: NikonBlowfish, key: number[],
                         cipherSsid: Uint8Array, cipherPw: Uint8Array,
                         allowEmptyPw: boolean, cbc: boolean): Promise<Uint8Array[] | null> {
  try {
    const ssid = cbc ? await blowfish.decryptCbcZeroIv(key, cipherSsid)
                     : await blowfish.decryptEcb(key, cipherSsid);
    if (!isPaddedPrintable(ssid, false)) return null;
    const pw = cbc ? await blowfish.decryptCbcZeroIv(key, cipherPw)
                   : await blowfish.decryptEcb(key, cipherPw);
    if (!isPaddedPrintable(pw, allowEmptyPw)) return null;
    return [ssid, pw];
  } catch (err) {
    return null;
  }
}
