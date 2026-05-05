/**
 * Photo entry model — extracted from PtpHost for shared use across pages.
 */
export interface PhotoEntry {
  handle: number;
  filename: string;
  size: number;
  // Extended fields from NAPI PtpObjectInfo (populated when available)
  captureDate?: string;
  objectFormat?: number;
  imagePixWidth?: number;
  imagePixHeight?: number;
  storageId?: number;
}
