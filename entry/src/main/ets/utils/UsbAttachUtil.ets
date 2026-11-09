/**
 * USB 插入去重。
 *
 * 相机插上之后常会重新枚举（`2-2` → `2-3` → `2-4`），`USB_DEVICE_ATTACHED`
 * 会连着发好几次；用 VID/PID/产品名做键，把同一台相机的事件收敛成一次。
 * 纯函数放在 utils 里，Local Test 可以直接覆盖。
 */
export function cameraAttachKey(vendorId: number, productId: number, productName: string): string {
  return `${vendorId}:${productId}:${productName}`;
}

/**
 * 同一个键在 `cooldownMs` 内只处理一次；不同相机立即处理。
 * `key === ''` 表示没有识别到相机，直接忽略。
 */
export function shouldHandleAttach(key: string, lastKey: string, lastAt: number,
  now: number, cooldownMs: number): boolean {
  if (key === '') {
    return false;
  }
  if (key !== lastKey) {
    return true;
  }
  return now - lastAt >= cooldownMs;
}
