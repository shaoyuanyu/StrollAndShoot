import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 尼康智能设备模式的 Blowfish 定键 CBC-MAC。
 *
 * 算法本身是标准 Blowfish（公开算法），尼康只固定了两样东西：
 * - 密钥：`FF FF AA 55 11 22 33 00`
 * - hash 初值：`0x01020304 / 0x05060708`，每轮 `E(block[i] ^ L, block[i+1] ^ R)`
 *
 * 之前打算移植 279 行 S 盒常量，但 HarmonyOS API 26 的 CryptoFramework
 * 原生支持 Blowfish（ECB/CBC），直接用系统实现即可。`selfTest()` 用公开
 * 标准向量（零密钥 + 全零块 → `4EF997456198DD78`）确认系统实现没跑偏。
 */
const NIKON_KEY: number[] = [0xFF, 0xFF, 0xAA, 0x55, 0x11, 0x22, 0x33, 0x00];
/** CryptoFramework 的算法名；不同版本可能要求 Blowfish64，失败时会回退。 */
const KEY_ALG = 'Blowfish';
const KEY_ALG_ALT = 'Blowfish64';

function u32ToBytesBE(l: number, r: number): Uint8Array {
  const out = new Uint8Array(8);
  out[0] = (l >>> 24) & 0xFF;
  out[1] = (l >>> 16) & 0xFF;
  out[2] = (l >>> 8) & 0xFF;
  out[3] = l & 0xFF;
  out[4] = (r >>> 24) & 0xFF;
  out[5] = (r >>> 16) & 0xFF;
  out[6] = (r >>> 8) & 0xFF;
  out[7] = r & 0xFF;
  return out;
}

function bytesToU32BE(data: Uint8Array): number[] {
  const l = ((data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3]) >>> 0;
  const r = ((data[4] << 24) | (data[5] << 16) | (data[6] << 8) | data[7]) >>> 0;
  return [l, r];
}

export class NikonBlowfish {
  private readonly onLog: (msg: string) => void;
  private algName: string = KEY_ALG;
  private ready: boolean = false;

  constructor(onLog: (msg: string) => void) {
    this.onLog = onLog;
  }

  /** 建一个指定模式的 cipher；算法名不支持时回退到 Blowfish64 并记住。 */
  private createCipher(modeSuffix: string): cryptoFramework.Cipher {
    try {
      return cryptoFramework.createCipher(`${this.algName}|${modeSuffix}`);
    } catch (err) {
      const alt = this.algName === KEY_ALG ? KEY_ALG_ALT : KEY_ALG;
      this.algName = alt;
      this.onLog(`[Blowfish] 回退算法串: ${alt}|${modeSuffix}`);
      return cryptoFramework.createCipher(`${alt}|${modeSuffix}`);
    }
  }

  private async symKey(keyBytes: number[]): Promise<cryptoFramework.SymKey> {
    const keyGen = cryptoFramework.createSymKeyGenerator(KEY_ALG);
    const keyBlob: cryptoFramework.DataBlob = { data: new Uint8Array(keyBytes) };
    return await keyGen.convertKey(keyBlob);
  }

  /** 用指定 8 字节密钥 ECB 加密一个块，返回 (L, R)。 */
  async encryptBlockWithKey(keyBytes: number[], l: number, r: number): Promise<number[]> {
    const symKey = await this.symKey(keyBytes);
    const cipher = this.createCipher('ECB|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, null);
    const input: cryptoFramework.DataBlob = { data: u32ToBytesBE(l, r) };
    const output = await cipher.doFinal(input);
    const bytes = new Uint8Array(output.data);
    return bytesToU32BE(bytes);
  }

  /** 用尼康定键加密一个块。 */
  async nikonEncryptBlock(l: number, r: number): Promise<number[]> {
    return await this.encryptBlockWithKey(NIKON_KEY, l, r);
  }

  /**
   * 用指定密钥做一次 CBC 解密，**整段一次解完**，IV 全零。
   *
   * 尼康 `0x2004` 的 SSID（32B）与密码（64B）是两个独立字段，各自 CBC、
   * IV 全零（还原报告 §3.4：库每次调用重读 IV、不回写终链）。所以这里不用
   * 逐块解，直接把整段丢给系统实现。
   */
  async decryptCbcZeroIv(keyBytes: number[], cipherBytes: Uint8Array): Promise<Uint8Array> {
    const symKey = await this.symKey(keyBytes);
    const cipher = this.createCipher('CBC|NoPadding');
    const iv: cryptoFramework.IvParamsSpec = {
      algName: 'IvParamsSpec',
      iv: { data: new Uint8Array(8) }
    };
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, iv);
    const output = await cipher.doFinal({ data: cipherBytes });
    return new Uint8Array(output.data);
  }

  /** 用指定密钥 ECB 解密整段（定键兜底路径用）。 */
  async decryptEcb(keyBytes: number[], cipherBytes: Uint8Array): Promise<Uint8Array> {
    const symKey = await this.symKey(keyBytes);
    const cipher = this.createCipher('ECB|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, null);
    const output = await cipher.doFinal({ data: cipherBytes });
    return new Uint8Array(output.data);
  }

  /**
   * 定键 CBC-MAC 式 hash：`blocks` 是 u32 序列（长度须为偶数），返回 (L, R)。
   * 与 ZPill 的 `BlowfishHasher.hash` 同构。
   */
  async hash(blocks: number[]): Promise<number[]> {
    if (blocks.length % 2 !== 0) {
      throw new Error('Blowfish hash 的 u32 块数须为偶数');
    }
    let left = 0x01020304;
    let right = 0x05060708;
    for (let i = 0; i < blocks.length; i += 2) {
      const l = (blocks[i] ^ left) >>> 0;
      const r = (blocks[i + 1] ^ right) >>> 0;
      const result = await this.nikonEncryptBlock(l, r);
      left = result[0];
      right = result[1];
    }
    return [left, right];
  }

  /**
   * 公开标准向量自测：零密钥加密全零块应为 `4EF997456198DD78`。
   * 通过说明系统 Blowfish 与标准实现一致，可以放心用于配对。
   */
  async selfTest(): Promise<boolean> {
    try {
      const zeroKey: number[] = [0, 0, 0, 0, 0, 0, 0, 0];
      const out = await this.encryptBlockWithKey(zeroKey, 0, 0);
      const ok = out[0] === 0x4EF99745 && out[1] === 0x6198DD78;
      this.onLog(`[Blowfish] 自测 ${ok ? '通过' : '失败'}: ${out[0].toString(16)}/${out[1].toString(16)}`);
      this.ready = ok;
      return ok;
    } catch (err) {
      this.onLog(`[Blowfish] 自测异常: ${(err as BusinessError).message}`);
      return false;
    }
  }

  isReady(): boolean {
    return this.ready;
  }
}
