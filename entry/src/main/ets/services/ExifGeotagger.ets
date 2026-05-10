import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { AppLog } from './AppLog';
import type { GpsRecord } from '../model/PhotoEntry';

export class ExifGeotagger {
  private static log: AppLog = new AppLog();

  static setLog(log: AppLog): void {
    ExifGeotagger.log = log;
  }

  /** Apply GPS coordinates via modifyImagePropertiesEnhanced (batch, writes to file in one go). */
  static async applyGps(filePath: string, gps: GpsRecord): Promise<boolean> {
    let imgSrc: image.ImageSource | null = null;
    let file: fileIo.File | null = null;

    try {
      file = fileIo.openSync(filePath, fileIo.OpenMode.READ_WRITE);
      imgSrc = image.createImageSource(file.fd);

      // Batch-write all GPS properties in one call. Keys are PropertyKey string values.
      const records: Record<string, string | null> = {
        'GPSLatitudeRef': gps.latitude >= 0 ? 'N' : 'S',
        'GPSLatitude': ExifGeotagger.toDmsStr(Math.abs(gps.latitude)),
        'GPSLongitudeRef': gps.longitude >= 0 ? 'E' : 'W',
        'GPSLongitude': ExifGeotagger.toDmsStr(Math.abs(gps.longitude)),
      };
      if (gps.altitude !== 0) {
        records['GPSAltitudeRef'] = gps.altitude >= 0 ? '0' : '1';
        records['GPSAltitude'] = Math.abs(gps.altitude).toFixed(1);
      }

      await imgSrc.modifyImagePropertiesEnhanced(records);

      // Verify
      const PK = image.PropertyKey;
      const v = await imgSrc.getImageProperties([
        PK.GPS_LATITUDE_REF, PK.GPS_LATITUDE, PK.GPS_LONGITUDE_REF, PK.GPS_LONGITUDE
      ]);
      ExifGeotagger.log.add(`GPS验证: ${JSON.stringify(v)}`);
      return true;
    } catch (err) {
      ExifGeotagger.log.add(`GPS异常: ${JSON.stringify(err)}`);
      return false;
    } finally {
      if (imgSrc) {
        try { imgSrc.release(); } catch (_e) { /* ignore */ }
      }
      if (file) {
        try { fileIo.closeSync(file); } catch (_e) { /* ignore */ }
      }
    }
  }

  /**
   * Convert decimal degrees to EXIF DMS string per HarmonyOS PropertyKey spec.
   * Format: "degrees,minutes,seconds" where seconds may have decimals.
   * Example: 43.8231 → "43,49,23.16"
   */
  private static toDmsStr(decimal: number): string {
    const degrees = Math.floor(decimal);
    const minutesFloat = (decimal - degrees) * 60;
    const minutes = Math.floor(minutesFloat);
    const seconds = ((minutesFloat - minutes) * 60);
    return `${degrees},${minutes},${seconds.toFixed(2)}`;
  }
}
