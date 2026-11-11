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
  /** 用户主动把相机切到 Wi-Fi（BLE 与 Wi-Fi 互斥，交接有代价，所以由用户点）。 */
  @Event onConnectWireless: () => void = () => {};

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
    // 未连接用灰点：琥珀色在「两种模式各自未连接」的场景下会显得像告警。
    return $r('app.color.text_tertiary');
  }

  /**
   * 连接区顶部的一句话状态。
   *
   * `statusText` 的初值是「就绪」，那是给扫描器用的；未连接且没在扫描时再显示
   * 「就绪」会让人以为已经连上了，这里换成明确的「未连接」。
   */
  private headerText(): ResourceStr {
    const busy = this.svc.connected || this.svc.scanning || this.svc.scanTotal > 0;
    if (busy && this.svc.statusText !== '') {
      return this.svc.statusText;
    }
    // 会话还没建立时，把链条上正在做的那一步讲出来：否则顶部一直写「未连接」，
    // 而下面两行在忙，又回到「状态互相打架」的老问题上。
    if (this.svc.bleConnecting) return $r('app.string.camera_ble_connecting');
    if (this.svc.wifiAutoConnecting) return $r('app.string.camera_conn_wifi_linking');
    if (this.svc.wifiReconnecting) return $r('app.string.camera_conn_wifi_relinking');
    return this.svc.connected
      ? $r('app.string.camera_status_connected')
      : $r('app.string.camera_conn_disconnected');
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
  // ------------------------------------------------------------------
  // 连接区（统一）
  //
  // 功能上只有两种连接方式，UI 必须按这两种讲，不能再把 USB / Wi-Fi / BLE
  // 摊成三张各自为政的卡片——那样会出现「上面写未连接相机、下面写已连接」
  // 的自相矛盾（2026-11-11 用户实测反馈）。
  // ------------------------------------------------------------------

  /** USB 会话（PTP over USB）。 */
  private usbConnected(): boolean {
    return this.svc.connected && !this.svc.wireless;
  }

  /** 无线会话（BLE 配对 + Wi-Fi STA 上的 PTP/IP）。 */
  private wifiConnected(): boolean {
    return this.svc.connected && this.svc.wireless;
  }

  /**
   * 配对是否真的落定。
   *
   * `bleConnected` 只代表 GATT 链路在（`connect()` 一返回就为真），配对要走完
   * 四步握手 / 断链 / 经典绑定 / 复用握手好几段，中间那几十秒两条状态会同时
   * 成立。UI 一律以「链路 ✓ 且拿到序列号」才算已配对，避免出现「正在连接」
   * 和「已连接」并存。
   */
  private blePaired(): boolean {
    return this.svc.bleConnected && this.svc.bleSerial !== '';
  }

  /** 蓝牙一句话状态。 */
  private bleStatusText(): ResourceStr {
    if (this.svc.bleConnecting) return $r('app.string.camera_ble_connecting');
    if (this.svc.bleReconnecting) return $r('app.string.camera_ble_reconnecting');
    if (this.blePaired()) {
      return this.svc.bleCameraName !== ''
        ? $r('app.string.camera_ble_connected_name', this.svc.bleCameraName)
        : $r('app.string.camera_ble_paired', this.svc.bleSerial);
    }
    if (this.svc.bleConnected) return $r('app.string.camera_ble_pair_failed');
    return $r('app.string.camera_conn_disconnected');
  }

  private bleStatusColor(): Resource {
    if (this.svc.bleConnecting) return $r('app.color.primary');
    if (this.svc.bleReconnecting) return $r('app.color.status_error');
    if (this.blePaired()) return $r('app.color.status_connected');
    if (this.svc.bleConnected) return $r('app.color.status_error');
    return $r('app.color.text_tertiary');
  }

  /**
   * 无线模式的前提说明。
   *
   * STA 模式是「相机加入手机所在网络」，这一步 App 代替不了：三方应用没有
   * 任何接口能读/配热点，`enableHotspot` 一类都要系统权限。所以只能把
   * 「手机要开热点、相机要选这个热点」讲清楚，而不是让用户对着空列表猜。
   *
   * 同时把本机网络快照与扫不到的原因摊开：分不清「我网络不对」和「相机没
   * 进 Wi-Fi 模式」是这条链路上最常见的卡点。
   */
  @Builder
  WirelessGuide() {
    Column({ space: 6 }) {
      if (this.svc.networkSummary !== '') {
        Text($r('app.string.camera_conn_network', this.svc.networkSummary))
          .fontSize(FontSize.Micro)
          .lineHeight(16)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      if (this.svc.wifiHint !== '') {
        Text(this.svc.wifiHint)
          .fontSize(FontSize.Micro)
          .lineHeight(16)
          .fontColor($r('app.color.status_error'))
          .width('100%')
      }
      Text($r('app.string.camera_conn_guide'))
        .fontSize(FontSize.Micro)
        .lineHeight(16)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 无线模式的「第几段」。
   *
   * 无线 = 蓝牙（配对/保活）+ Wi-Fi STA（照片通道）。以前只有「已连接 /
   * 未连接」两态，于是「蓝牙已配对、正在接无线」这段几十秒被显示成
   * 「未连接」，看起来像什么都没做。现在把中间态讲出来：
   *
   * - 已连上：无线会话在；
   * - 蓝牙好了、正在自动接无线：显示进度；
   * - 蓝牙好了、无线还没起来：半个状态，需要用户/机制继续推进；
   * - 都没有：未连接。
   */
  private wirelessStatusText(): ResourceStr {
    if (this.wifiConnected()) return $r('app.string.camera_conn_connected');
    if (this.svc.wifiAutoConnecting) return $r('app.string.camera_conn_wifi_linking');
    if (this.svc.wifiReconnecting) return $r('app.string.camera_conn_wifi_relinking');
    if (this.blePaired()) return $r('app.string.camera_conn_wifi_waiting');
    return $r('app.string.camera_conn_disconnected');
  }

  private wirelessStatusColor(): Resource {
    if (this.wifiConnected()) return $r('app.color.status_connected');
    if (this.svc.wifiAutoConnecting || this.svc.wifiReconnecting) return $r('app.color.primary');
    // 蓝牙就绪但无线没通：不是「正在做」，是真没连上，给告警色。
    if (this.blePaired()) return $r('app.color.status_error');
    return $r('app.color.text_tertiary');
  }

  /** 卡片内的模式块外壳：左侧状态点 + 模式名 + 右侧状态。 */
  @Builder
  ModeHeader(title: Resource, sub: ResourceStr, on: boolean, status: ResourceStr,
             statusColor: Resource) {
    Row({ space: 8 }) {
      Row()
        .width(6).height(6).borderRadius(pillRadius(6))
        .backgroundColor(on ? $r('app.color.status_connected') : $r('app.color.text_tertiary'))
      Text(title)
        .fontSize(FontSize.Body)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      if (sub !== '') {
        Text(sub)
          .fontSize(FontSize.Micro)
          .fontColor($r('app.color.text_tertiary'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor($r('app.color.bg_page'))
          .borderRadius(Radius.Chip)
      }
      Blank()
      Text(status)
        .fontSize(FontSize.Caption)
        .fontColor(statusColor)
    }
    .width('100%')
  }

  /** 连接卡：一张卡讲清「USB」和「无线」两种模式。 */
  @Builder
  ConnectionCard() {
    Column({ space: 14 }) {
      // 统一状态头：PTP 会话的真实状态 + 相机名 + 扫描进度
      Column({ space: 6 }) {
        Row({ space: 10 }) {
          Row()
            .width(8).height(8).borderRadius(pillRadius(8))
            .backgroundColor(this.statusColor())
          Text(this.headerText())
            .fontSize(FontSize.CardTitle)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .maxLines(2)
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
          Text(this.svc.cameraName)
            .fontSize(FontSize.Body)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }

        if (this.svc.lastScanError !== '') {
          Text(this.svc.lastScanError)
            .fontSize(FontSize.Caption)
            .lineHeight(18)
            .fontColor($r('app.color.status_error'))
            .width('100%')
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

      // 模式一：USB
      Column({ space: 6 }) {
        this.ModeHeader(
          $r('app.string.camera_conn_usb'),
          '',
          this.usbConnected(),
          this.usbConnected() ? $r('app.string.camera_conn_connected')
                             : $r('app.string.camera_conn_disconnected'),
          this.usbConnected() ? $r('app.color.status_connected')
                              : $r('app.color.text_tertiary'))
        Text($r('app.string.camera_conn_usb_hint'))
          .fontSize(FontSize.Caption)
          .lineHeight(18)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      .width('100%')
      .padding(12)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.filter_chip_bg'))
      .borderRadius(Radius.Inner)

      // 模式二：无线（蓝牙 + Wi-Fi STA）
      Column({ space: 10 }) {
        this.ModeHeader(
          $r('app.string.camera_conn_wireless'),
          $r('app.string.camera_conn_wireless_sub'),
          this.wifiConnected(),
          this.wirelessStatusText(),
          this.wirelessStatusColor())

        // 蓝牙：配对与保活，是无线模式的前置
        Row({ space: 8 }) {
          Text($r('app.string.camera_conn_ble'))
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.text_secondary'))
            .flexShrink(0)
          Text(this.bleStatusText())
            .fontSize(FontSize.Caption)
            .fontColor(this.bleStatusColor())
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          // 连接/配对进行中给「取消连接」而不是「断开蓝牙」：这几十秒里链路
          // 可能已通但配对还没落定，写「断开」会和「正在连接」打架。
          if (this.svc.bleConnecting) {
            Text($r('app.string.camera_ble_cancel'))
              .fontSize(FontSize.Caption)
              .fontColor($r('app.color.text_secondary'))
              .onClick(() => { this.onDisconnectBle(); })
          } else if (this.svc.bleConnected || this.svc.bleReconnecting) {
            Text($r('app.string.camera_ble_disconnect'))
              .fontSize(FontSize.Caption)
              .fontColor($r('app.color.button_danger'))
              .onClick(() => { this.onDisconnectBle(); })
          }
        }
        .width('100%')

        // 蓝牙已就绪、无线还没起：这是「相机现在在蓝牙模式」的正常状态。
        // 给一个明确的交接按钮，用户点一下才把相机推到 Wi-Fi（互斥，不自动做）。
        if (this.blePaired() && !this.wifiConnected() && !this.svc.wifiAutoConnecting) {
          Button($r('app.string.camera_conn_open_wifi'))
            .width('100%')
            .height(44)
            .fontSize(FontSize.Body)
            .borderRadius(pillRadius(44))
            .backgroundColor($r('app.color.primary'))
            .fontColor($r('app.color.text_on_primary'))
            .onClick(() => { this.onConnectWireless(); })
          Text($r('app.string.camera_conn_open_wifi_hint'))
            .fontSize(FontSize.Micro)
            .lineHeight(16)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }

        // Wi-Fi：已连接显示地址，未连接给地址输入与发现入口
        if (this.wifiConnected()) {
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
              .backgroundColor($r('app.color.bg_surface'))
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
              .backgroundColor($r('app.color.bg_surface'))
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

          Row({ space: 16 }) {
            Text(this.svc.wifiScanning
              ? $r('app.string.camera_wifi_scanning')
              : $r('app.string.camera_wifi_scan_nearby'))
              .fontSize(FontSize.Caption)
              .fontColor($r('app.color.primary'))
              .onClick(() => {
                if (!this.svc.wifiScanning) {
                  this.onScanWifi();
                }
              })
            if (!this.svc.bleConnected) {
              Text(this.svc.bleScanning
                ? $r('app.string.camera_ble_scanning')
                : $r('app.string.camera_ble_scan'))
                .fontSize(FontSize.Caption)
                .fontColor(this.svc.bleScanning || this.svc.bleConnecting
                  ? $r('app.color.text_tertiary')
                  : $r('app.color.primary'))
                .onClick(() => {
                  if (!this.svc.bleScanning && !this.svc.bleConnecting) {
                    this.onScanBle();
                  }
                })
            }
            Blank()
          }
          .width('100%')

          this.WirelessGuide()

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

          if (this.svc.bleCameras.length > 0) {
            Column() {
              ForEach(this.svc.bleCameras, (cam: BleCameraDevice) => {
                Row({ space: 8 }) {
                  Text(cam.name !== '' ? cam.name : $r('app.string.camera_ble_unnamed'))
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
      }
      .width('100%')
      .padding(12)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.filter_chip_bg'))
      .borderRadius(Radius.Inner)
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(Radius.Card)
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: 16 }) {
        // 连接区统一成一张卡：两种模式（USB / 无线）各自给出自己的状态，
        // 顶部只保留 PTP 会话的真实状态，不再是三张卡各说各话。
        this.ConnectionCard()
        if (this.svc.pairingRequired) {
          this.PairingCard()
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
