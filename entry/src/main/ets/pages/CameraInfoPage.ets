/**
 * CameraInfoPage.ets
 *
 * 相机设备信息二级页。
 *
 * 相机页的抽屉只保留一个「设备信息」入口，品牌、型号、序列号、固件、连接方式
 * 与照片数量全部收在这里。这样四种链路（USB / 蓝牙 / Wi-Fi AP / Wi-Fi STA）
 * 在主页面上长得一样，不会因为某个模式没有 PTP 会话就少一整块内容。
 *
 * 只读页面，没有操作。数据全部从 `CameraService` 与已保存的相机记录派生：
 * PTP 会话在时优先用 PTP 读到的值；只有蓝牙待机时退回 GATT / 广播名里的
 * 固件与序列号；都没读到就不画那一行，不写「未知」占位。
 *
 * **不显示相机 Wi-Fi 的 IP 与端口**：那是连接细节，不是设备信息；用户不需要
 * 拿它做任何事，放在页面上只会增加噪音。
 */
import { CameraService } from '../services/CameraService';
import { BleIdentityStore } from '../services/BleIdentityStore';
import { CameraModelStore } from '../model/CameraModelStore';
import { SavedCameraStore } from '../services/SavedCameraStore';
import { CameraLinkMode } from '../model/CameraLinkMode';
import { cameraSerialFromBleName, cameraStandeeKey, cameraStandeeLabel } from '../utils/CameraStandee';
import { PageHeader } from '../components/PageHeader';
import { L10n } from '../utils/L10n';
import { CardShadow, FontSize, Radius } from '../utils/UiTokens';

/** 只读信息行的高度（vp）：比操作行矮一档，靠密度区分「数据」与「操作」。 */
const INFO_ROW_HEIGHT = 44;

@Builder
export function CameraInfoPageBuilder() {
  CameraInfoPage();
}

@ComponentV2
export struct CameraInfoPage {
  private pageInfos: NavPathStack = new NavPathStack();
  @Local svc: CameraService = CameraService.getInstance();

  build() {
    NavDestination() {
      Column() {
        PageHeader({
          title: $r('app.string.camera_group_device'),
          subtitle: this.cameraTitle(),
          onBack: () => { this.pageInfos.pop(); }
        })

        Scroll() {
          Column({ space: 10 }) {
            if (!this.hasDeviceInfo()) {
              Column({ space: 6 }) {
                Text($r('app.string.camera_info_empty'))
                  .fontSize(FontSize.Body)
                  .fontColor($r('app.color.text_secondary'))
                Text($r('app.string.camera_info_empty_hint'))
                  .fontSize(FontSize.Caption)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
              .padding({ top: 80 })
            } else {
              this.SectionTitle($r('app.string.settings_section_camera'))
              Column() {
                if (this.svc.mockSession()) {
                  CameraInfoValueRow({
                    label: $r('app.string.camera_info_mock'),
                    value: $r('app.string.camera_info_mock_value'),
                    last: !this.hasCameraFields()
                  })
                }
                if (this.brandText() !== '') {
                  CameraInfoValueRow({
                    label: $r('app.string.camera_info_brand'),
                    value: this.brandText(),
                    last: !this.hasCameraFieldsAfterBrand()
                  })
                }
                if (this.modelText() !== '') {
                  CameraInfoValueRow({
                    label: $r('app.string.camera_info_model'),
                    value: this.modelText(),
                    last: !this.hasCameraFieldsAfterModel()
                  })
                }
                if (this.serialText() !== '') {
                  CameraInfoValueRow({
                    label: $r('app.string.camera_info_serial'),
                    value: this.serialText(),
                    last: !this.hasCameraFieldsAfterSerial()
                  })
                }
                if (this.firmwareText() !== '') {
                  CameraInfoValueRow({
                    label: $r('app.string.camera_info_firmware'),
                    value: this.firmwareText(),
                    last: true
                  })
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16 })
              .backgroundColor($r('app.color.bg_surface'))
              .borderRadius(Radius.Card)
              .shadow(CardShadow)

              this.SectionTitle($r('app.string.camera_info_section_connection'))
              Column() {
                CameraInfoValueRow({
                  label: $r('app.string.camera_info_connection'),
                  value: this.connectionText(),
                  last: !this.hasUsbFields()
                })
                if (this.svc.usbVidPid !== '') {
                  CameraInfoValueRow({
                    label: $r('app.string.camera_info_usb_id'),
                    value: this.svc.usbVidPid,
                    last: this.svc.usbSerialNumber === ''
                  })
                }
                if (this.svc.usbSerialNumber !== '') {
                  CameraInfoValueRow({
                    label: $r('app.string.camera_info_usb_serial'),
                    value: this.svc.usbSerialNumber,
                    last: true
                  })
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16 })
              .backgroundColor($r('app.color.bg_surface'))
              .borderRadius(Radius.Card)
              .shadow(CardShadow)

              if (this.hasDataFields()) {
                this.SectionTitle($r('app.string.camera_info_section_data'))
                Column() {
                  if (this.photoCountVisible()) {
                    CameraInfoValueRow({
                      label: $r('app.string.camera_info_photo_count'),
                      value: this.photoCountText(),
                      last: this.svc.cameraIdentity === ''
                    })
                  }
                  if (this.svc.cameraIdentity !== '') {
                    CameraInfoValueRow({
                      label: $r('app.string.camera_info_cache_id'),
                      value: this.svc.cameraIdentity,
                      last: true
                    })
                  }
                }
                .width('100%')
                .padding({ left: 16, right: 16 })
                .backgroundColor($r('app.color.bg_surface'))
                .borderRadius(Radius.Card)
                .shadow(CardShadow)
              }
            }

            Row().width('100%').height(24)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
    })
  }

  @Builder
  SectionTitle(title: ResourceStr) {
    Text(title)
      .fontSize(FontSize.Section)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ left: 4, top: 6 })
  }

  /** 页头副标题：认出机型时显示官方型号名，认不出时退回「相机」。 */
  private cameraTitle(): ResourceStr {
    const model = this.modelText();
    return model !== '' ? model : $r('app.string.tab_camera');
  }

  /**
   * 型号：优先用识别出的立牌 key（`cameraModel`），它已经是展示口径。
   *
   * 没有 key 时再看 PTP / BLE 原始名；BLE 广播名里带序列号，但 `cameraStandeeKey()`
   * 仍能从中认出机型。认不出来就原样显示，至少不让页面空着。
   */
  private modelText(): string {
    const raw = this.rawModelName();
    const key = this.svc.cameraModel !== '' ? this.svc.cameraModel : cameraStandeeKey(raw);
    const label = cameraStandeeLabel(key);
    if (label !== '') return label;
    return raw;
  }

  private rawModelName(): string {
    if (this.svc.cameraName !== '') return this.svc.cameraName;
    if (this.svc.bleCameraName !== '') return this.svc.bleCameraName;
    const rec = SavedCameraStore.getInstance().current();
    return rec !== null ? rec.cameraName : '';
  }

  /**
   * 序列号：PTP 优先，其次 BLE 广播名尾段，最后才用落盘的展示序列号。
   *
   * PTP 返回的是 32 位补零串，去掉前导零才和相机菜单里那串一致。BLE 的
   * `bleSerial` 是身份序列号，不是展示序列号，不能放进来。
   */
  private serialText(): string {
    const ptp = this.svc.deviceSerialNumber.replace(/^0+/, '');
    if (ptp !== '') return ptp;
    const fromBle = cameraSerialFromBleName(this.svc.bleCameraName);
    if (fromBle !== '') return fromBle;
    const stored = CameraModelStore.getInstance().serial;
    if (stored !== '') return stored;
    const rec = SavedCameraStore.getInstance().current();
    return rec !== null ? rec.serial : '';
  }

  private brandText(): string {
    return this.svc.deviceManufacturer;
  }

  /** 固件：PTP 优先；只有蓝牙待机时 GATT 的 `0x180A/0x2A26` 是唯一来源。 */
  private firmwareText(): string {
    if (this.svc.deviceVersion !== '') return this.svc.deviceVersion;
    return this.svc.bleFirmware;
  }

  private connectionText(): string {
    const mode = this.modeText();
    if (this.linked()) return `${mode} · ${L10n.tr('camera_status_connected')}`;
    if (this.known()) return `${mode} · ${L10n.tr('camera_state_paired')}`;
    return `${mode} · ${L10n.tr('camera_conn_disconnected')}`;
  }

  private modeText(): string {
    const m = this.svc.linkMode;
    if (m === CameraLinkMode.USB) return L10n.tr('camera_mode_usb');
    if (m === CameraLinkMode.BLE) return L10n.tr('camera_mode_ble');
    if (m === CameraLinkMode.AP) return L10n.tr('camera_mode_ap');
    return L10n.tr('camera_mode_sta');
  }

  /** 与相机页 `linked()` 同一套口径：三种链路的「已连接」不是同一个字段。 */
  private linked(): boolean {
    const m = this.svc.linkMode;
    if (m === CameraLinkMode.USB) return this.svc.connected && !this.svc.wireless;
    if (m === CameraLinkMode.BLE) {
      return (this.svc.bleConnected && this.svc.bleSerial !== '')
        || (this.svc.connected && this.svc.wireless);
    }
    return this.svc.connected && this.svc.wireless;
  }

  /** 已配对 / 有落盘记录：没连着时连接方式一栏显示「已配对」而不是「未连接」。 */
  private known(): boolean {
    if (this.svc.bleConnected && this.svc.bleSerial !== '') return true;
    const identity = BleIdentityStore.getInstance();
    if (identity.hasIdentity() && identity.deviceId !== '') return true;
    return SavedCameraStore.getInstance().pickReal() !== null;
  }

  private hasCameraFields(): boolean {
    return this.brandText() !== '' || this.modelText() !== '' || this.serialText() !== ''
      || this.firmwareText() !== '';
  }

  private hasUsbFields(): boolean {
    return this.svc.usbVidPid !== '' || this.svc.usbSerialNumber !== '';
  }

  private hasCameraFieldsAfterBrand(): boolean {
    return this.modelText() !== '' || this.serialText() !== '' || this.firmwareText() !== '';
  }

  private hasCameraFieldsAfterModel(): boolean {
    return this.serialText() !== '' || this.firmwareText() !== '';
  }

  private hasCameraFieldsAfterSerial(): boolean {
    return this.firmwareText() !== '';
  }

  private photoCountVisible(): boolean {
    return this.svc.connected || this.svc.photoCount > 0;
  }

  private photoCountText(): ResourceStr {
    return $r('app.plural.photo_count', this.svc.photoCount, this.svc.photoCount);
  }

  private hasDataFields(): boolean {
    return this.photoCountVisible() || this.svc.cameraIdentity !== '';
  }

  private hasDeviceInfo(): boolean {
    return this.hasCameraFields() || this.svc.mockSession() || this.hasDataFields();
  }
}

/** 只读设备信息行：标签 → 值，最后一行不画分隔线。 */
@ComponentV2
struct CameraInfoValueRow {
  @Param label: ResourceStr = '';
  @Param value: ResourceStr = '';
  @Param last: boolean = false;

  build() {
    Row() {
      Text(this.label)
        .fontSize(FontSize.Body)
        .fontColor($r('app.color.text_secondary'))
        .flexShrink(0)
      Text(this.value)
        .fontSize(FontSize.Body)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
        .layoutWeight(1)
        .margin({ left: 16 })
    }
    .width('100%')
    .height(INFO_ROW_HEIGHT)
    .border({ width: { bottom: this.last ? 0 : 0.5 }, color: $r('app.color.divider') })
  }
}
