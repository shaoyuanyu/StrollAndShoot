import localUnitTest from './LocalUnit.test';
import photoGroupUtilTest from './PhotoGroupUtil.test';
import gpsTrackTest from './GpsTrack.test';
import gpsFormatTest from './GpsFormat.test';
import gpsMockTrackTest from './GpsMockTrack.test';
import galleryZoomTest from './GalleryZoom.test';
import persistenceTest from './Persistence.test';
import ptpSchedulerTest from './PtpScheduler.test';
import usbAttachUtilTest from './UsbAttachUtil.test';
import nikonWifiCredentialsTest from './NikonWifiCredentials.test';
import cameraStandeeTest from './CameraStandee.test';
import blePayloadsTest from './BlePayloads.test';

export default function testsuite() {
  localUnitTest();
  photoGroupUtilTest();
  gpsTrackTest();
  gpsFormatTest();
  gpsMockTrackTest();
  galleryZoomTest();
  persistenceTest();
  ptpSchedulerTest();
  usbAttachUtilTest();
  nikonWifiCredentialsTest();
  cameraStandeeTest();
  blePayloadsTest();
}