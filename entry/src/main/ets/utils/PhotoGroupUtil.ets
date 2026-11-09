import type { PhotoEntry, DisplayGroup } from '../model/PhotoEntry';

export function getExt(filename: string): string {
  const dot = filename.lastIndexOf('.');
  if (dot < 0) return '';
  return filename.substring(dot + 1).toUpperCase();
}

export function getBasename(filename: string): string {
  const dot = filename.lastIndexOf('.');
  if (dot < 0) return filename;
  return filename.substring(0, dot);
}

const FORMAT_PRIORITY: Map<string, number> = new Map([
  ['JPEG', 100], ['JPG', 99],
  ['PNG', 80],
  ['HEIC', 70], ['HEIF', 70],
  ['TIF', 60], ['TIFF', 60],
  ['NEF', 30], ['CR2', 30], ['CR3', 30], ['ARW', 30],
  ['DNG', 30], ['RAF', 30], ['ORF', 30], ['RW2', 30],
  ['PEF', 30], ['SRW', 30], ['NRW', 30], ['3FR', 30],
  ['ERF', 30], ['KDC', 30], ['MRW', 30], ['X3F', 30],
]);

export function getFormatPriority(ext: string): number {
  return FORMAT_PRIORITY.get(ext.toUpperCase()) ?? 0;
}

export function groupPhotosByBasename(photos: PhotoEntry[]): DisplayGroup[] {
  const map = new Map<string, PhotoEntry[]>();
  for (const p of photos) {
    const bn = getBasename(p.filename);
    const arr = map.get(bn);
    if (arr) {
      arr.push(p);
    } else {
      map.set(bn, [p]);
    }
  }

  const groups: DisplayGroup[] = [];
  map.forEach((entries: PhotoEntry[], basename: string) => {
    entries.sort((a: PhotoEntry, b: PhotoEntry) => {
      const pa = getFormatPriority(getExt(a.filename));
      const pb = getFormatPriority(getExt(b.filename));
      return pb - pa; // descending priority
    });
    groups.push({
      basename: basename,
      displayPhoto: entries[0],
      alternates: entries.slice(1),
      allPhotos: entries
    });
  });

  groups.sort((a: DisplayGroup, b: DisplayGroup) => {
    const da = a.displayPhoto.captureDate || '';
    const db = b.displayPhoto.captureDate || '';
    if (da !== db) return db.localeCompare(da);
    return a.basename.localeCompare(b.basename);
  });
  return groups;
}

/**
 * 拍摄时间 → 修改时间 → handle 降序。与 `CameraService.publishPhotoList()` 的发布排序保持一致。
 */
function compareByTimeDesc(a: PhotoEntry, b: PhotoEntry): number {
  const da = a.captureDate || '';
  const db = b.captureDate || '';
  if (da !== db) return db.localeCompare(da);
  const ma = a.modificationDate || '';
  const mb = b.modificationDate || '';
  if (ma !== mb) return mb.localeCompare(ma);
  return b.handle - a.handle;
}

/** 同组内 JPG 在前、RAW 在后；同优先级再按时间排，不依赖 Array#sort 是否稳定。 */
function compareByFormat(a: PhotoEntry, b: PhotoEntry): number {
  const byPriority =
    getFormatPriority(getExt(b.filename)) - getFormatPriority(getExt(a.filename));
  if (byPriority !== 0) return byPriority;
  return compareByTimeDesc(a, b);
}

/**
 * 文件优先模式：一个文件一个格子，但**同一张照片的多个文件必须挨在一起**（JPG 在前、RAW 在后）。
 *
 * 不能只按时间 + handle 排（2026-11-09 真机反馈：「文件优先」下 JPG 与 NEF 不成对）。
 * 实测 Nikon Z50 的 1288 个文件：644 组 JPG+NEF 里有 438 组被拆开，原因有两个 ——
 * 1. 连拍的照片 EXIF 时间戳落在**同一秒**（如 DSC_4477/4478/4479 都是 213747），
 *    时间键完全相同，只能靠 handle 兜底；而相机按格式分段分配 handle
 *    （JPEG 在 689508xxx、NEF 在 152637xxx），于是同一秒内所有 JPG 都排在所有 NEF 前面。
 * 2. 另有 66 组两个文件的 EXIF 时间相差 1 秒（如 DSC_3840.NEF=140428、.JPG=140427），
 *    时间键本身就不同。
 *
 * 做法：先按时间整体排好，再以「同名文件的**首次出现位置**」为锚，把它们收成相邻块。
 * 锚点取首次出现（即该组最新的那个文件），所以整体仍是倒序，只牺牲 1 秒级精度。
 */
export function buildFileFirstGroups(photos: PhotoEntry[]): DisplayGroup[] {
  const sorted = photos.slice();
  sorted.sort(compareByTimeDesc);

  const buckets = new Map<string, PhotoEntry[]>();
  for (const p of sorted) {
    const bn = getBasename(p.filename);
    const arr = buckets.get(bn);
    if (arr) {
      arr.push(p);
    } else {
      buckets.set(bn, [p]);
    }
  }

  const groups: DisplayGroup[] = [];
  const emitted = new Set<string>();
  for (const p of sorted) {
    const bn = getBasename(p.filename);
    if (emitted.has(bn)) continue;
    emitted.add(bn);
    const bucket = buckets.get(bn) as PhotoEntry[];
    bucket.sort(compareByFormat);
    for (const q of bucket) {
      groups.push({
        basename: bn,
        displayPhoto: q,
        alternates: [],
        allPhotos: [q]
      });
    }
  }
  return groups;
}

export function buildDisplayGroups(photos: PhotoEntry[], mode: string): DisplayGroup[] {
  if (mode === 'content_first') {
    return groupPhotosByBasename(photos);
  }
  return buildFileFirstGroups(photos);
}
