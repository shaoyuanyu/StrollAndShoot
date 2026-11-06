import localUnitTest from './LocalUnit.test';
import photoGroupUtilTest from './PhotoGroupUtil.test';
import gpsTrackTest from './GpsTrack.test';

export default function testsuite() {
  localUnitTest();
  photoGroupUtilTest();
  gpsTrackTest();
}