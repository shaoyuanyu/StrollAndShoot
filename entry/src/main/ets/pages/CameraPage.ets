import { CameraService } from '../services/CameraService';
import { titleBarTotalVp } from '../utils/TitleBarMetrics';
import { FontSize, IconSize, Radius, RowHeight, pillRadius } from '../utils/UiTokens';
import type { WifiCameraInfo } from '../services/NsdScanner';
import type { BleCameraDevice } from '../services/BleScanner';

/**
 * 相机页。
 *
 * 沉浸光感规则：内容区的 Button 拿不到系统材质，所以「搜索相机 / 快速扫描」
 * 这个主操作放在标题栏里（见 MainScreen.NormalTitleRow），本页只负责状态与设备信息。
 * 卡片统一 24vp 圆角、无描边，与官方设置页的白卡形态对齐。
 */
@ComponentV2
export struct CameraPage {
  @Local svc: CameraService = CameraService.getInstance();
  @Param scroller: Scroller = new Scroller();
  @Event onScan: (quickMode: boolean) => void = (_q: boolean) => {};
  @Event onDisconnect: () => void = () => {};
  @Event onConnectWifi: (host: string) => void = (_h: string) => {};
  @Event onCompletePairing: () => void = () => {};
  @Event onScanWifi: () => void = () => {};
  @Event onScanBle: () => void = () => {};
  @Event onConnectBle: (deviceId: string, deviceName: string) => void =
    (_id: string, _name: string) => {};
  @Event onDisconnectBle: () => void = () => {};

  /** 无线连接输入框；首次进入用上次成功的地址预填。 */
  @Local wifiInput: string = '';

  aboutToAppear(): void {
    if (this.wifiInput === '' && this.svc.wifiHost !== '') {
      this.wifiInput = this.svc.wifiHost;
    }
  }

  private statusColor(): Resource {
    if (this.svc.scanning) return $r('app.color.primary');
    // connected 只代表 PTP 会话建立；存储读不到时要显式报警（ISSUE-003）。
    if (this.svc.connected && this.svc.usable) return $r('app.color.status_connected');
    if (this.svc.connected) return $r('app.color.status_error');
    return $r('app.color.status_disconnected');
  }

  @Builder
  StatusCard() {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        Row()
          .width(8).height(8).borderRadius(pillRadius(8))
          .backgroundColor(this.statusColor())
        // 永远优先显示 statusText：以前 connected 为真时写死成“已连接”，
        // 导致连上相机之后所有失败原因都不可见（ISSUE-001）。
        Text(this.svc.statusText !== ''
          ? this.svc.statusText
          : (this.svc.connected
            ? $r('app.string.camera_status_connected')
            : $r('app.string.camera_empty_title')))
          .fontSize(FontSize.CardTitle)
          .layoutWeight(1)
          .maxLines(2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        if (this.svc.connected && this.svc.photoCount > 0) {
          Text($r('app.plural.photo_count', this.svc.photoCount, this.svc.photoCount))
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.primary'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor($r('app.color.primary_soft'))
            .borderRadius(Radius.Chip)
        }
      }
      .width('100%')

      if (this.svc.connected) {
        Column({ space: 4 }) {
          Text(this.svc.cameraName)
            .fontSize(FontSize.Body)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.svc.cameraIdentity)
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      if (this.svc.scanTotal > 0) {
        Column({ space: 6 }) {
          Progress({
            value: this.svc.scanProgress,
            total: this.svc.scanTotal,
            type: ProgressType.Linear
          })
            .width('100%').height(3)
            .color($r('app.color.primary'))
            .backgroundColor($r('app.color.divider'))
          Row() {
            Text(this.svc.scanPhaseText || $r('app.string.camera_scanning_fallback'))
              .fontSize(FontSize.Caption).fontColor($r('app.color.text_secondary'))
            Blank()
            Text(`${this.svc.scanProgress}/${this.svc.scanTotal}`)
              .fontSize(FontSize.Caption).fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
        }
        .width('100%')
      }

      if (this.svc.scanStatsText) {
        Text(this.svc.scanStatsText)
          .fontSize(FontSize.Caption)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(Radius.Card)
  }

  /** 未连接时的空态：不再放整块大按钮，主操作在标题栏右上角。 */
  @Builder
  EmptyCard() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.camera'))
        .fontSize(IconSize.Empty)
        .fontColor([$r('app.color.text_tertiary')])
      Text($r('app.string.camera_empty_title'))
        .fontSize(FontSize.CardTitle)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 2 })
      Text($r('app.string.camera_empty_hint'))
        .fontSize(FontSize.Caption)
        .lineHeight(20)
        .textAlign(TextAlign.Center)
        .fontColor($r('app.color.text_secondary'))
      // 扫描失败的原因在未连接态也要显示出来，否则用户只看到“没反应”。
      if (this.svc.lastScanError !== '') {
        Text(this.svc.lastScanError)
          .fontSize(FontSize.Caption)
          .lineHeight(20)
          .textAlign(TextAlign.Center)
          .fontColor($r('app.color.status_error'))
      }
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 48, bottom: 48 })
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(Radius.Card)
  }

  @Builder
  DeviceCard() {
    Column() {
      CameraInfoRow({ label: $r('app.string.camera_info_brand'), value: this.svc.deviceManufacturer || $r('app.string.common_unknown') })
      CameraInfoRow({ label: $r('app.string.camera_info_model'), value: this.svc.cameraName || $r('app.string.common_unknown') })
      CameraInfoRow({ label: $r('app.string.camera_info_serial'), value: this.svc.deviceSerialNumber || $r('app.string.common_none') })
      CameraInfoRow({ label: $r('app.string.camera_info_firmware'), value: this.svc.deviceVersion || $r('app.string.common_unknown') })
      CameraInfoRow({ label: $r('app.string.camera_info_usb_id'), value: this.svc.usbVidPid || $r('app.string.common_unknown') })
      CameraInfoRow({ label: $r('app.string.camera_info_usb_serial'), value: this.svc.usbSerialNumber || $r('app.string.common_none') })
      CameraInfoRow({ label: $r('app.string.camera_info_cache_id'), value: this.svc.cameraIdentity || $r('app.string.common_none') })
      CameraInfoRow({ label: $r('app.string.camera_info_photo_count'), value: `${this.svc.photoCount}` })
      CameraInfoRow({
        label: $r('app.string.camera_info_connection'),
        value: this.svc.wireless ? `Wi-Fi · ${this.svc.wifiHost}` : $r('app.string.camera_connection_ptp')
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(Radius.Card)
  }

  /** 次要操作单独一张卡：全量扫描（会丢缓存）与断开连接。 */
  @Builder
  ActionsCard() {
    Column() {
      CameraActionRow({
        label: $r('app.string.camera_action_full_scan'),
        subtitle: $r('app.string.camera_action_full_scan_desc'),
        disabled: this.svc.scanning,
        onTap: () => { this.onScan(false); }
      })
      CameraActionRow({
        label: $r('app.string.camera_action_disconnect'),
        danger: true,
        last: true,
        onTap: () => { this.onDisconnect(); }
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(Radius.Card)
  }

  /**
   * 无线连接卡。
   *
   * 只做「填地址 → 连接」这一件事：发现（mDNS / 网段扫描）与 BLE 配对
   * 留在后续迭代，先把 PTP/IP 链路跑通。已连接时显示当前地址与断开入口。
   */
  @Builder
  WirelessCard() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.wifi'))
          .fontSize(IconSize.Body)
          .fontColor([$r('app.color.primary')])
        Text($r('app.string.camera_wifi_title'))
          .fontSize(FontSize.CardTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        if (this.svc.wireless) {
          Text($r('app.string.camera_status_connected'))
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.status_connected'))
        }
      }
      .width('100%')

      Text($r('app.string.camera_wifi_hint'))
        .fontSize(FontSize.Caption)
        .lineHeight(18)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')

      if (this.svc.wireless) {
        Row({ space: 12 }) {
          Text(`${this.svc.wifiHost}:${this.svc.wifiPort}`)
            .fontSize(FontSize.Body)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Button($r('app.string.camera_wifi_disconnect'))
            .height(36)
            .fontSize(FontSize.Caption)
            .borderRadius(pillRadius(36))
            .backgroundColor($r('app.color.filter_chip_bg'))
            .fontColor($r('app.color.text_primary'))
            .onClick(() => { this.onDisconnect(); })
        }
        .width('100%')
      } else {
        Row({ space: 8 }) {
          TextInput({
            placeholder: $r('app.string.camera_wifi_host_placeholder'),
            text: this.wifiInput
          })
            .height(40)
            .layoutWeight(1)
            .fontSize(FontSize.Body)
            .borderRadius(Radius.Chip)
            .backgroundColor($r('app.color.filter_chip_bg'))
            .onChange((value: string) => { this.wifiInput = value; })
            .onSubmit(() => {
              if (this.wifiInput.trim() !== '' && !this.svc.scanning) {
                this.onConnectWifi(this.wifiInput.trim());
              }
            })
          Button($r('app.string.camera_wifi_connect'))
            .height(40)
            .fontSize(FontSize.Body)
            .borderRadius(pillRadius(40))
            .backgroundColor($r('app.color.primary'))
            .fontColor($r('app.color.text_on_primary'))
            .enabled(!this.svc.scanning && this.wifiInput.trim() !== '')
            .onClick(() => { this.onConnectWifi(this.wifiInput.trim()); })
        }
        .width('100%')

        // mDNS 发现：相机广播 `_ptp._tcp`，实例名就是机身名，点一下就连。
        Text(this.svc.wifiScanning
          ? $r('app.string.camera_wifi_scanning')
          : $r('app.string.camera_wifi_scan_nearby'))
          .fontSize(FontSize.Caption)
          .fontColor($r('app.color.primary'))
          .width('100%')
          .onClick(() => {
            if (!this.svc.wifiScanning) {
              this.onScanWifi();
            }
          })

        if (this.svc.wifiCameras.length > 0) {
          Column() {
            ForEach(this.svc.wifiCameras, (cam: WifiCameraInfo) => {
              Row({ space: 8 }) {
                Text(cam.name)
                  .fontSize(FontSize.Body)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(cam.host)
                  .fontSize(FontSize.Caption)
                  .fontColor($r('app.color.text_tertiary'))
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(IconSize.Body)
                  .fontColor([$r('app.color.text_tertiary')])
              }
              .width('100%')
              .padding({ top: 10, bottom: 10 })
              .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
              .onClick(() => { this.onConnectWifi(cam.host); })
            }, (cam: WifiCameraInfo) => cam.name)
          }
          .width('100%')
        }
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(Radius.Card)
  }

  /**
   * 配对核对卡。
   *
   * 相机在「连接向导」页等主机注册：它先开 15740 让我们连上，再等 0x952B
   * 取的验证码与 0x935A 确认；不确认就 10 秒后收线、Wi-Fi 配置不落盘。
   */
  @Builder
  PairingCard() {
    Column({ space: 14 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.link'))
          .fontSize(IconSize.Body)
          .fontColor([$r('app.color.primary')])
        Text($r('app.string.camera_wifi_pairing_title'))
          .fontSize(FontSize.CardTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')

      Text(this.svc.pairingCode)
        .fontSize(40)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.primary'))
        .letterSpacing(8)
        .width('100%')
        .textAlign(TextAlign.Center)

      Text($r('app.string.camera_wifi_pairing_hint'))
        .fontSize(FontSize.Caption)
        .lineHeight(18)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')

      Button($r('app.string.camera_wifi_pairing_confirm'))
        .width('100%')
        .height(44)
        .borderRadius(pillRadius(44))
        .backgroundColor($r('app.color.primary'))
        .fontColor($r('app.color.text_on_primary'))
        .onClick(() => { this.onCompletePairing(); })
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(Radius.Card)
  }

  /**
   * 蓝牙卡。
   *
   * 状态分四档，必须能看出链路是否还活着（相机休眠会自己断链，链路断开后
   * 会按退避自动重连，用户要看得到这个过程）：
   *
   * - 连接中（bond + GATT 最长几十秒）
   * - 重连中（断链后在退避重连）
   * - 已连接（复用握手通过，校时与保活都在跑）
   * - 已配对但未连接
   */
  @Builder
  BleCard() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text($r('app.string.camera_ble_title'))
          .fontSize(FontSize.CardTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        if (this.svc.bleConnecting) {
          Text($r('app.string.camera_ble_connecting'))
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.primary'))
        } else if (this.svc.bleReconnecting) {
          Text($r('app.string.camera_ble_reconnecting'))
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.status_error'))
        } else if (this.svc.bleConnected && this.svc.bleSerial !== '') {
          Text(this.svc.bleCameraName !== ''
            ? $r('app.string.camera_ble_connected_name', this.svc.bleCameraName)
            : $r('app.string.camera_ble_paired', this.svc.bleSerial))
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.status_connected'))
        } else if (this.svc.bleConnected) {
          Text($r('app.string.camera_ble_pair_failed'))
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.status_error'))
        }
      }
      .width('100%')

      Text($r('app.string.camera_ble_hint'))
        .fontSize(FontSize.Caption)
        .lineHeight(18)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')

      Text(this.svc.bleScanning
        ? $r('app.string.camera_ble_scanning')
        : $r('app.string.camera_ble_scan'))
        .fontSize(FontSize.Caption)
        .fontColor($r('app.color.primary'))
        .width('100%')
        .onClick(() => {
          if (!this.svc.bleScanning) {
            this.onScanBle();
          }
        })

      if (this.svc.bleConnected || this.svc.bleReconnecting) {
        Text($r('app.string.camera_ble_disconnect'))
          .fontSize(FontSize.Caption)
          .fontColor($r('app.color.button_danger'))
          .width('100%')
          .onClick(() => { this.onDisconnectBle(); })
      }

      if (this.svc.bleCameras.length > 0) {
        Column() {
          ForEach(this.svc.bleCameras, (cam: BleCameraDevice) => {
            Row({ space: 8 }) {
              Text(cam.name)
                .fontSize(FontSize.Body)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${cam.rssi} dBm`)
                .fontSize(FontSize.Caption)
                .fontColor($r('app.color.text_tertiary'))
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(IconSize.Body)
                .fontColor([$r('app.color.text_tertiary')])
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
            .enabled(!this.svc.bleConnecting && !this.svc.bleConnected)
            .onClick(() => { this.onConnectBle(cam.deviceId, cam.name); })
          }, (cam: BleCameraDevice) => cam.deviceId)
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(Radius.Card)
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: 16 }) {
        if (this.svc.connected || this.svc.scanning || this.svc.scanTotal > 0) {
          this.StatusCard()
        } else {
          this.EmptyCard()
        }
        if (this.svc.pairingRequired) {
          this.PairingCard()
        } else if (!this.svc.connected) {
          this.WirelessCard()
          this.BleCard()
        }
        if (this.svc.connected) {
          this.DeviceCard()
          this.ActionsCard()
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 96 })
    }
    .width('100%').height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    // 标题栏浮在内容之上，首屏内容按其高度内缩；滚动时从标题栏下方穿过
    .contentStartOffset(titleBarTotalVp())
  }
}

/** 设备信息行。 */
@ComponentV2
struct CameraInfoRow {
  @Param label: ResourceStr = '';
  @Param value: ResourceStr = '';

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
    .height(RowHeight.Single)
    .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
  }
}

/** 设备卡里的操作行：普通操作带右箭头，危险操作用红字。 */
@ComponentV2
struct CameraActionRow {
  @Param label: ResourceStr = '';
  @Param subtitle: ResourceStr = '';
  @Param danger: boolean = false;
  @Param disabled: boolean = false;
  @Param last: boolean = false;
  @Event onTap: () => void = () => {};

  build() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(this.label)
          .fontSize(FontSize.CardTitle)
          .fontColor(this.danger ? $r('app.color.button_danger') : $r('app.color.text_primary'))
          .alignSelf(ItemAlign.Start)
        if (this.subtitle !== '') {
          Text(this.subtitle)
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.text_tertiary'))
            .alignSelf(ItemAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (!this.danger) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(IconSize.Body)
          .fontColor([$r('app.color.text_tertiary')])
      }
    }
    .width('100%')
    .padding({ top: 14, bottom: 14 })
    .opacity(this.disabled ? 0.4 : 1)
    .border({ width: { bottom: this.last ? 0 : 0.5 }, color: $r('app.color.divider') })
    .onClick(() => {
      if (!this.disabled) {
        this.onTap();
      }
    })
  }
}
