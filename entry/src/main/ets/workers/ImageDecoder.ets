/**
 * ImageDecoder.ets
 * 
 * TaskPool 并发解码函数 — 在后台线程中执行图片解码，不阻塞 UI 线程。
 * 
 * PixelMap 属于 Transferable (NativeBinding) 对象（转移模式），
 * 在 @Concurrent 函数中创建 PixelMap 后调用 setTransferDetached(true)，
 * 可将所有权转移到主线程。
 * 
 * 注意：此文件必须与 UI 组件完全分离——不能 import 任何 UI 装饰器
 * （@ComponentV2 等），否则子线程初始化时会崩溃。
 */

import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

// 注意：@Concurrent 函数不能访问文件级变量（属于闭包），
// 因此 TAG/DOMAIN 需要在每个函数中定义为局部常量。

/**
 * 在 TaskPool 工作线程中解码缩略图。
 * 应用 EXIF 旋转/翻转，然后根据原始照片尺寸裁剪黑边。
 *
 * @param data      - 原始缩略图 JPEG 数据 (ArrayBuffer)
 * @param rotate    - EXIF 旋转角度 (0/90/180/270)
 * @param flipH     - EXIF 水平翻转
 * @param flipV     - EXIF 垂直翻转
 * @param origW     - 原始照片宽度（来自 exifOrigDims，0 = 未知）
 * @param origH     - 原始照片高度（来自 exifOrigDims，0 = 未知）
 * @returns 裁剪后的 PixelMap（已 setTransferDetached）
 */
@Concurrent
export async function decodeThumbnailTask(
  data: ArrayBuffer,
  rotate: number,
  flipH: boolean,
  flipV: boolean,
  origW: number,
  origH: number
): Promise<image.PixelMap> {
  const TAG = 'ImageDecoder';
  const DOMAIN = 0x0000;
  const t0 = Date.now();
  const imageSource = image.createImageSource(data);
  const needsFlip = flipH || flipV;
  const needsRotate = rotate !== 0;
  const pixelMap = await imageSource.createPixelMap({ editable: needsFlip || needsRotate });

  if (needsRotate) {
    await pixelMap.rotate(rotate);
  }
  if (needsFlip) {
    pixelMap.flip(flipH, flipV);
  }

  // 根据原始尺寸裁剪黑边
  const imgInfo = await pixelMap.getImageInfo();
  const tw = imgInfo.size.width;
  const th = imgInfo.size.height;

  let cropW: number;
  let cropH: number;
  if (origW > 0 && origH > 0) {
    let ow = origW;
    let oh = origH;
    // 如果旋转角度为 90°/270°，交换原始宽高
    if (rotate === 90 || rotate === 270) {
      const tmp = ow;
      ow = oh;
      oh = tmp;
    }
    const scale = Math.min(tw / ow, th / oh);
    cropW = Math.floor(ow * scale);
    cropH = Math.floor(oh * scale);
  } else {
    cropW = tw;
    cropH = th;
  }

  const region: image.Region = {
    x: Math.floor((tw - cropW) / 2),
    y: Math.floor((th - cropH) / 2),
    size: { width: cropW, height: cropH }
  };
  const cropped = await pixelMap.createCroppedAndScaledPixelMap(region, 1.0, 1.0);
  pixelMap.release();
  imageSource.release();

  // 所有权转移到主线程
  cropped.setTransferDetached(true);

  const t1 = Date.now();
  hilog.info(DOMAIN, TAG, `thumb decode done in ${t1 - t0}ms crop=${cropW}x${cropH}`);
  return cropped;
}

/**
 * 在 TaskPool 工作线程中解码全分辨率照片。
 * 应用 EXIF 旋转/翻转，不裁剪。
 *
 * @param data      - 原始全分辨率照片数据 (ArrayBuffer)
 * @param rotate    - EXIF 旋转角度 (0/90/180/270)
 * @param flipH     - EXIF 水平翻转
 * @param flipV     - EXIF 垂直翻转
 * @returns 解码后的 PixelMap（已 setTransferDetached）
 */
@Concurrent
export async function decodeFullPhotoTask(
  data: ArrayBuffer,
  rotate: number,
  flipH: boolean,
  flipV: boolean
): Promise<image.PixelMap> {
  const TAG = 'ImageDecoder';
  const DOMAIN = 0x0000;
  const t0 = Date.now();
  const imageSource = image.createImageSource(data);
  const needsFlip = flipH || flipV;
  const needsRotate = rotate !== 0;
  const pixelMap = await imageSource.createPixelMap({ editable: needsFlip || needsRotate });

  if (needsRotate) {
    await pixelMap.rotate(rotate);
  }
  if (needsFlip) {
    pixelMap.flip(flipH, flipV);
  }
  imageSource.release();

  pixelMap.setTransferDetached(true);

  const t1 = Date.now();
  const info = await pixelMap.getImageInfo();
  hilog.info(DOMAIN, TAG, `full decode done ${info.size.width}x${info.size.height} in ${t1 - t0}ms`);
  return pixelMap;
}
