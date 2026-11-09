import localUnitTest from './LocalUnit.test';
import photoGroupUtilTest from './PhotoGroupUtil.test';
import gpsTrackTest from './GpsTrack.test';
import gpsFormatTest from './GpsFormat.test';
import gpsMockTrackTest from './GpsMockTrack.test';
import galleryZoomTest from './GalleryZoom.test';
import persistenceTest from './Persistence.test';
import ptpSchedulerTest from './PtpScheduler.test';

export default function testsuite() {
  localUnitTest();
  photoGroupUtilTest();
  gpsTrackTest();
  gpsFormatTest();
  gpsMockTrackTest();
  galleryZoomTest();
  persistenceTest();
  ptpSchedulerTest();
}