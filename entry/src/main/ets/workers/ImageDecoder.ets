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
  const needsFlip = flipH || flipV;
  const needsRotate = rotate !== 0;
  let imageSource: image.ImageSource | null = null;
  let pixelMap: image.PixelMap | null = null;

  try {
    imageSource = image.createImageSource(data);
    const pm = await imageSource.createPixelMap({ editable: needsFlip || needsRotate });
    pixelMap = pm;

    hilog.info(DOMAIN, TAG, '[CROP] start orient=(%{public}d,%{public}s,%{public}s) orig=%{public}dx%{public}d',
      rotate, flipH.toString(), flipV.toString(), origW, origH);

    if (needsRotate) {
      await pm.rotate(rotate);
    }
    if (needsFlip) {
      pm.flip(flipH, flipV);
    }

    // 根据原始尺寸裁剪黑边
    const imgInfo = await pm.getImageInfo();
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
      hilog.info(DOMAIN, TAG, '[CROP] thumb=%{public}dx%{public}d scale=%{public}s crop=%{public}dx%{public}d',
        tw, th, scale.toFixed(4), cropW, cropH);
    } else {
      cropW = tw;
      cropH = th;
      hilog.info(DOMAIN, TAG, '[CROP] no orig dims, skip crop thumb=%{public}dx%{public}d', tw, th);
    }

    const region: image.Region = {
      x: Math.floor((tw - cropW) / 2),
      y: Math.floor((th - cropH) / 2),
      size: { width: cropW, height: cropH }
    };
    const cropped = await pm.createCroppedAndScaledPixelMap(region, 1.0, 1.0);

    // 所有权转移到主线程
    cropped.setTransferDetached(true);

    const t1 = Date.now();
    hilog.info(DOMAIN, TAG, `thumb decode done in ${t1 - t0}ms crop=${cropW}x${cropH}`);
    return cropped;
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'thumb decode failed: %{public}s', JSON.stringify(err));
    throw new Error(`thumb decode failed: ${JSON.stringify(err)}`);
  } finally {
    if (pixelMap) {
      try {
        pixelMap.release();
      } catch (_e) { /* ignore */ }
    }
    if (imageSource) {
      try {
        imageSource.release();
      } catch (_e) { /* ignore */ }
    }
  }
}

/**
 * 在 TaskPool 工作线程中解码全分辨率照片。
 * 应用 EXIF 旋转/翻转，不裁剪。
 *
 * 解码尺寸按最长边限制（`maxEdge`，0 表示不限制）：手机屏幕长边约 2700px，
 * 预览器最多 5x 捏合，3072px 已经够用；而 24MP 原图（6000×4000）全尺寸解码
 * 是 96MB/张，预览器同时驻留 6-7 张会把内存和显存带宽打满。
 *
 * @param data      - 原始全分辨率照片数据 (ArrayBuffer)
 * @param rotate    - EXIF 旋转角度 (0/90/180/270)
 * @param flipH     - EXIF 水平翻转
 * @param flipV     - EXIF 垂直翻转
 * @param maxEdge   - 解码后最长边上限（px），0 = 不限制
 * @returns 解码后的 PixelMap（已 setTransferDetached）
 */
@Concurrent
export async function decodeFullPhotoTask(
  data: ArrayBuffer,
  rotate: number,
  flipH: boolean,
  flipV: boolean,
  maxEdge: number
): Promise<image.PixelMap> {
  const TAG = 'ImageDecoder';
  const DOMAIN = 0x0000;
  const t0 = Date.now();
  const needsFlip = flipH || flipV;
  const needsRotate = rotate !== 0;
  let imageSource: image.ImageSource | null = null;
  let pixelMap: image.PixelMap | null = null;

  try {
    imageSource = image.createImageSource(data);
    const options: image.DecodingOptions = { editable: needsFlip || needsRotate };
    let decodeScale = 1;
    if (maxEdge > 0) {
      const srcInfo = await imageSource.getImageInfo();
      const longEdge = Math.max(srcInfo.size.width, srcInfo.size.height);
      if (longEdge > maxEdge) {
        decodeScale = maxEdge / longEdge;
        options.desiredSize = {
          width: Math.max(1, Math.round(srcInfo.size.width * decodeScale)),
          height: Math.max(1, Math.round(srcInfo.size.height * decodeScale))
        };
      }
    }
    const pm = await imageSource.createPixelMap(options);
    pixelMap = pm;

    if (needsRotate) {
      await pm.rotate(rotate);
    }
    if (needsFlip) {
      pm.flip(flipH, flipV);
    }

    pm.setTransferDetached(true);

    const t1 = Date.now();
    const info = await pm.getImageInfo();
    hilog.info(DOMAIN, TAG, `full decode done ${info.size.width}x${info.size.height} in ${t1 - t0}ms scale=${decodeScale.toFixed(3)}`);
    return pm;
  } catch (err) {
    if (pixelMap) {
      try {
        pixelMap.release();
      } catch (_e) { /* ignore */ }
    }
    hilog.error(DOMAIN, TAG, 'full decode failed: %{public}s', JSON.stringify(err));
    throw new Error(`full decode failed: ${JSON.stringify(err)}`);
  } finally {
    if (imageSource) {
      try {
        imageSource.release();
      } catch (_e) { /* ignore */ }
    }
  }
}
