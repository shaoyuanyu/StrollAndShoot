import { CameraService } from '../services/CameraService';
import { CameraLinkMode } from '../model/CameraLinkMode';
import type { BleCameraDevice } from '../services/BleScanner';

/**
 * 相机页状态预演（仅调试包）。
 *
 * 模拟器上没有 USB 主机、没有真实相机，蓝牙 / Wi-Fi 交接也没法走完整条链路，
 * 但相机页的状态是由 `CameraService` 的字段推出来的。这里直接把这些字段摆成
 * 某个真实状态的样子，页面就会按真实逻辑渲染——用于逐状态截图验收，
 * 不参与任何真实连接、也不写持久化。
 *
 * 触发方式（应用已在前台）：
 *   hdc shell aa start -a EntryAbility -b <bundle> --ps demo ap_connected
 * 然后照常 `--ps shot <label>` 截应用窗口。
 *
 * 只由 `EntryAbility.onNewWant` 在 `MockPtpDevice.isDebugBuild()` 为真时调用；
 * release 包没有入口。
 */
export class CameraStateDemo {
  private static readonly CAM_NAME: string = 'Z50_2';
  private static readonly CAM_MODEL: string = 'z50ii';
  private static readonly SERIAL: string = '8079350';
  private static readonly BLE_NAME: string = 'Z50_2_8079350';
  private static readonly AP_HOST: string = '192.168.1.1';
  private static readonly STA_HOST: string = '192.168.1.5';
  private static readonly PHOTO_COUNT: number = 38;

  /** 预演一个命名状态；名字见 `apply` 的 switch。 */
  static apply(name: string): void {
    const s = CameraService.getInstance();
    CameraStateDemo.reset(s);
    switch (name) {
      // ---- USB ----
      case 'usb_idle':
        s.linkMode = CameraLinkMode.USB;
        break;
      case 'usb_searching':
        s.linkMode = CameraLinkMode.USB;
        s.scanning = true;
        s.statusText = '正在搜索 USB 相机…';
        break;
      case 'usb_connected':
        s.linkMode = CameraLinkMode.USB;
        CameraStateDemo.connectedDevice(s, false);
        s.usbVidPid = '04B0:044C';
        s.usbSerialNumber = CameraStateDemo.SERIAL;
        break;
      case 'usb_failed':
        s.linkMode = CameraLinkMode.USB;
        s.lastScanError = '未检测到 USB 相机';
        s.statusText = '未检测到 USB 相机';
        break;
      case 'usb_loading':
        s.linkMode = CameraLinkMode.USB;
        CameraStateDemo.connectedDevice(s, false);
        s.usbVidPid = '04B0:044C';
        s.usbSerialNumber = CameraStateDemo.SERIAL;
        s.scanning = true;
        s.photoCount = 0;
        s.scanTotal = CameraStateDemo.PHOTO_COUNT;
        s.scanProgress = 17;
        s.scanPhaseText = '正在读取缩略图…';
        s.statusText = '正在获取照片列表...';
        break;

      // ---- BLE ----
      case 'ble_idle':
        s.linkMode = CameraLinkMode.BLE;
        break;
      case 'ble_scanning':
        s.linkMode = CameraLinkMode.BLE;
        s.bleScanning = true;
        s.bleCameras = CameraStateDemo.bleDevices();
        break;
      case 'ble_connecting':
        s.linkMode = CameraLinkMode.BLE;
        s.bleConnecting = true;
        s.bleCameraName = CameraStateDemo.BLE_NAME;
        break;
      case 'ble_pair_failed':
        s.linkMode = CameraLinkMode.BLE;
        s.bleConnected = true;
        s.bleCameraName = CameraStateDemo.BLE_NAME;
        break;
      case 'ble_connected':
        s.linkMode = CameraLinkMode.BLE;
        CameraStateDemo.pairedBle(s);
        break;
      case 'ble_reconnecting':
        s.linkMode = CameraLinkMode.BLE;
        s.bleCameraName = CameraStateDemo.BLE_NAME;
        s.bleReconnecting = true;
        break;

      // ---- Wi-Fi AP ----
      case 'ap_idle':
        s.linkMode = CameraLinkMode.AP;
        break;
      case 'ap_pair_scanning':
        s.linkMode = CameraLinkMode.AP;
        s.bleScanning = true;
        s.bleCameras = CameraStateDemo.bleDevices();
        break;
      case 'ap_pairing':
        s.linkMode = CameraLinkMode.AP;
        s.bleConnecting = true;
        s.bleCameraName = CameraStateDemo.BLE_NAME;
        break;
      case 'ap_pair_failed':
        s.linkMode = CameraLinkMode.AP;
        s.bleConnected = true;
        s.bleCameraName = CameraStateDemo.BLE_NAME;
        break;
      case 'ap_ready':
        s.linkMode = CameraLinkMode.AP;
        CameraStateDemo.pairedBle(s);
        break;
      case 'ap_connecting':
        s.linkMode = CameraLinkMode.AP;
        CameraStateDemo.pairedBle(s);
        s.apJoining = true;
        s.wirelessStage = '正在连接相机热点';
        break;
      case 'ap_connected':
        s.linkMode = CameraLinkMode.AP;
        CameraStateDemo.connectedDevice(s, true);
        s.wifiHost = CameraStateDemo.AP_HOST;
        break;
      case 'ap_pairing_code':
        s.linkMode = CameraLinkMode.AP;
        CameraStateDemo.connectedDevice(s, true);
        s.wifiHost = CameraStateDemo.AP_HOST;
        s.photoCount = 0;
        s.pairingRequired = true;
        s.pairingCode = '483921';
        s.statusText = '相机等待配对';
        break;
      case 'ap_failed':
        s.linkMode = CameraLinkMode.AP;
        s.wirelessFailed = '连接相机热点超时';
        break;
      case 'ap_reconnecting':
        s.linkMode = CameraLinkMode.AP;
        s.wireless = true;
        s.wifiReconnecting = true;
        break;
      case 'ap_disconnecting':
        s.linkMode = CameraLinkMode.AP;
        CameraStateDemo.connectedDevice(s, true);
        s.wifiHost = CameraStateDemo.AP_HOST;
        s.disconnecting = true;
        s.wirelessStage = '正在退出相机热点';
        break;
      case 'ap_switching':
        s.linkMode = CameraLinkMode.AP;
        CameraStateDemo.connectedDevice(s, true);
        s.wifiHost = CameraStateDemo.AP_HOST;
        s.switchingTo = CameraLinkMode.BLE;
        s.disconnecting = true;
        break;

      // ---- Wi-Fi STA ----
      case 'sta_idle':
        s.linkMode = CameraLinkMode.STA;
        break;
      case 'sta_scanning':
        s.linkMode = CameraLinkMode.STA;
        // 自动发现是「连接」的一部分：页面收起正文，只在状态头写搜索/连接。
        s.wifiAutoConnecting = true;
        s.wifiScanning = true;
        break;
      case 'sta_connecting':
        s.linkMode = CameraLinkMode.STA;
        CameraStateDemo.pairedBle(s);
        s.wifiAutoConnecting = true;
        break;
      case 'sta_connected':
        s.linkMode = CameraLinkMode.STA;
        CameraStateDemo.connectedDevice(s, true);
        s.wifiHost = CameraStateDemo.STA_HOST;
        break;
      case 'sta_failed':
        s.linkMode = CameraLinkMode.STA;
        // 自动搜索失败：原因同时写进 wirelessFailed 与 wifiHint，页面只在
        // 状态头显示一次（正文的红字在 Failed 阶段不再重复）。
        s.wifiHint = '同一网络里没有发现相机。确认相机已进入「连接至智能设备」的 Wi-Fi 模式。';
        s.wirelessFailed = s.wifiHint;
        break;
      case 'sta_reconnecting':
        s.linkMode = CameraLinkMode.STA;
        s.wireless = true;
        s.wifiReconnecting = true;
        break;

      default:
        s.linkMode = CameraLinkMode.BLE;
        break;
    }
    s.getLog().add(`[demo] 状态预演: ${name}`);
  }

  /** 回到「什么都没连」的干净状态，预演之间不串味。 */
  static reset(s: CameraService): void {
    s.connected = false;
    s.wireless = false;
    s.usable = false;
    s.scanning = false;
    s.statusText = '';
    s.cameraName = '';
    s.cameraModel = CameraStateDemo.CAM_MODEL;
    s.photoCount = 0;
    s.photos = [];
    s.wifiHost = '';
    s.wifiPort = 15740;
    s.pairingCode = '';
    s.pairingRequired = false;
    s.wifiCameras = [];
    s.wifiScanning = false;
    s.wifiAutoConnecting = false;
    s.wifiConnecting = false;
    s.wifiReconnecting = false;
    s.wifiHint = '';
    s.bleHint = '';
    s.apJoining = false;
    s.wirelessStage = '';
    s.wirelessFailed = '';
    s.disconnecting = false;
    s.switchingTo = -1;
    s.bleCameras = [];
    s.bleScanning = false;
    s.bleConnecting = false;
    s.bleConnected = false;
    s.bleServices = [];
    s.bleSerial = '';
    s.bleCameraName = '';
    s.bleReconnecting = false;
    s.lastScanError = '';
    s.scanStatsText = '';
    s.scanPhaseText = '';
    s.scanProgress = 0;
    s.scanTotal = 0;
    s.cameraIdentity = '';
    s.deviceManufacturer = 'Nikon';
    s.deviceSerialNumber = '';
    s.deviceVersion = '';
    s.usbVidPid = '';
    s.usbSerialNumber = '';
  }

  /** 已连上一台 Z 50II：设备信息、照片数与身份字段都填满。 */
  private static connectedDevice(s: CameraService, wireless: boolean): void {
    s.connected = true;
    s.wireless = wireless;
    s.usable = true;
    s.scanning = false;
    s.cameraName = CameraStateDemo.CAM_NAME;
    s.cameraModel = CameraStateDemo.CAM_MODEL;
    s.cameraIdentity = `Nikon_${CameraStateDemo.CAM_NAME}_${CameraStateDemo.SERIAL}`;
    s.deviceManufacturer = 'Nikon';
    s.deviceSerialNumber = CameraStateDemo.SERIAL;
    s.deviceVersion = '2.00';
    s.photoCount = CameraStateDemo.PHOTO_COUNT;
    s.statusText = '已连接';
  }

  /** BLE 配对落定：链路在、序列号在。 */
  private static pairedBle(s: CameraService): void {
    s.bleConnected = true;
    s.bleSerial = CameraStateDemo.SERIAL;
    s.bleCameraName = CameraStateDemo.BLE_NAME;
    s.cameraModel = CameraStateDemo.CAM_MODEL;
  }

  private static bleDevices(): BleCameraDevice[] {
    return [
      { deviceId: 'C4:2F:90:1A:33:01', name: CameraStateDemo.BLE_NAME, rssi: -52, nikonDeviceId: 8079350 },
      { deviceId: 'C4:2F:90:1A:33:02', name: 'Z_fc_2210345', rssi: -71, nikonDeviceId: 2210345 }
    ];
  }

}
