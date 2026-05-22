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

export function buildFileFirstGroups(photos: PhotoEntry[]): DisplayGroup[] {
  const groups: DisplayGroup[] = [];
  for (const p of photos) {
    groups.push({
      basename: getBasename(p.filename),
      displayPhoto: p,
      alternates: [],
      allPhotos: [p]
    });
  }
  return groups;
}

export function buildDisplayGroups(photos: PhotoEntry[], mode: string): DisplayGroup[] {
  if (mode === 'content_first') {
    return groupPhotosByBasename(photos);
  }
  return buildFileFirstGroups(photos);
}
