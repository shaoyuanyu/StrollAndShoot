import { CameraService } from '../services/CameraService';
import { titleBarTotalVp } from '../utils/TitleBarMetrics';

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

  private statusColor(): Resource {
    if (this.svc.connected) return $r('app.color.status_connected');
    if (this.svc.scanning) return $r('app.color.primary');
    return $r('app.color.status_disconnected');
  }

  @Builder
  StatusCard() {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        Row()
          .width(8).height(8).borderRadius(4)
          .backgroundColor(this.statusColor())
        Text(this.svc.connected ? '已连接' : (this.svc.statusText || '未连接相机'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        if (this.svc.connected && this.svc.photoCount > 0) {
          Text(`${this.svc.photoCount} 张`)
            .fontSize(13)
            .fontColor($r('app.color.primary'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor($r('app.color.primary_soft'))
            .borderRadius(12)
        }
      }
      .width('100%')

      if (this.svc.connected) {
        Column({ space: 4 }) {
          Text(this.svc.cameraName)
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.svc.cameraIdentity)
            .fontSize(11)
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
            Text(this.svc.scanPhaseText || '正在扫描')
              .fontSize(11).fontColor($r('app.color.text_secondary'))
            Blank()
            Text(`${this.svc.scanProgress}/${this.svc.scanTotal}`)
              .fontSize(11).fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
        }
        .width('100%')
      }

      if (this.svc.scanStatsText) {
        Text(this.svc.scanStatsText)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(24)
  }

  /** 未连接时的空态：不再放整块大按钮，主操作在标题栏右上角。 */
  @Builder
  EmptyCard() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.camera'))
        .fontSize(44)
        .fontColor([$r('app.color.text_tertiary')])
      Text('未连接相机')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 2 })
      Text('用 USB 数据线连接相机，并选择 PTP 传输模式\n然后点右上角的「搜索相机」')
        .fontSize(13)
        .lineHeight(20)
        .textAlign(TextAlign.Center)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 48, bottom: 48 })
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(24)
  }

  @Builder
  DeviceCard() {
    Column() {
      CameraInfoRow({ label: '品牌', value: this.svc.deviceManufacturer || '未知' })
      CameraInfoRow({ label: '型号', value: this.svc.cameraName || '未知' })
      CameraInfoRow({ label: '序列号', value: this.svc.deviceSerialNumber || '无' })
      CameraInfoRow({ label: '固件版本', value: this.svc.deviceVersion || '未知' })
      CameraInfoRow({ label: 'USB 识别码', value: this.svc.usbVidPid || '未知' })
      CameraInfoRow({ label: 'USB 序列号', value: this.svc.usbSerialNumber || '无' })
      CameraInfoRow({ label: '缓存标识', value: this.svc.cameraIdentity || '无' })
      CameraInfoRow({ label: '照片数量', value: `${this.svc.photoCount}` })
      CameraInfoRow({ label: '连接方式', value: 'USB PTP' })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(24)
  }

  /** 次要操作单独一张卡：全量扫描（会丢缓存）与断开连接。 */
  @Builder
  ActionsCard() {
    Column() {
      CameraActionRow({
        label: '全量扫描',
        subtitle: '忽略缓存，重新读取所有文件的元数据与缩略图',
        disabled: this.svc.scanning,
        onTap: () => { this.onScan(false); }
      })
      CameraActionRow({
        label: '断开连接',
        danger: true,
        last: true,
        onTap: () => { this.onDisconnect(); }
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(24)
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: 16 }) {
        if (this.svc.connected || this.svc.scanning || this.svc.scanTotal > 0) {
          this.StatusCard()
        } else {
          this.EmptyCard()
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
  @Param label: string = '';
  @Param value: string = '';

  build() {
    Row() {
      Text(this.label)
        .fontSize(15)
        .fontColor($r('app.color.text_secondary'))
        .flexShrink(0)
      Text(this.value)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
        .layoutWeight(1)
        .margin({ left: 16 })
    }
    .width('100%')
    .height(52)
    .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
  }
}

/** 设备卡里的操作行：普通操作带右箭头，危险操作用红字。 */
@ComponentV2
struct CameraActionRow {
  @Param label: string = '';
  @Param subtitle: string = '';
  @Param danger: boolean = false;
  @Param disabled: boolean = false;
  @Param last: boolean = false;
  @Event onTap: () => void = () => {};

  build() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(this.label)
          .fontSize(16)
          .fontColor(this.danger ? $r('app.color.button_danger') : $r('app.color.text_primary'))
          .alignSelf(ItemAlign.Start)
        if (this.subtitle !== '') {
          Text(this.subtitle)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .alignSelf(ItemAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (!this.danger) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
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
