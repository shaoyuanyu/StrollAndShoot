/**
 * PairedCamerasPage.ets
 *
 * 「已配对相机」：管理落盘的相机身份（`SavedCameraStore`）。
 *
 * 入口在设置页「相机 → 已配对相机」。以前只能从相机页标题栏的下拉菜单里切相机，
 * 那个菜单一次只看得到「其它几台」，既看不到全部、也没法删掉不用的记录。这里
 * 是它的完整视图：台数、当前是哪台、模拟设备、切换与删除。
 */
import { PageHeader } from '../components/PageHeader';
import { CameraService } from '../services/CameraService';
import { SavedCameraStore, type SavedCamera } from '../services/SavedCameraStore';
import { cameraStandeeLabel } from '../utils/CameraStandee';
import { L10n } from '../utils/L10n';
import { CardShadow, FontSize, IconSize, Radius } from '../utils/UiTokens';

@Builder
export function PairedCamerasPageBuilder() {
  PairedCamerasPage();
}

@ComponentV2
export struct PairedCamerasPage {
  private pageInfos: NavPathStack = new NavPathStack();
  @Local cameraStore: SavedCameraStore = SavedCameraStore.getInstance();
  @Local svc: CameraService = CameraService.getInstance();

  /** 行标题：型号（设备号）；没有型号时退回相机广播名。 */
  private cameraText(cam: SavedCamera): string {
    const label = cameraStandeeLabel(cam.modelKey);
    const name = label !== '' ? label : cam.cameraName;
    if (cam.serial !== '' && name !== '' && name !== cam.serial) {
      return L10n.tr('camera_title_with_serial', name, cam.serial);
    }
    if (name !== '') return name;
    return cam.key;
  }

  /**
   * 当前是否还有活链路。
   *
   * 切换相机会改写活动身份与机型/序列号，此时必须先把旧会话断开，否则标题、立牌
   * 会指向新相机、会话却还在旧相机上。判定口径与标题栏下拉菜单一致。
   */
  private linked(): boolean {
    if (this.svc.connected) return true;
    if (this.svc.bleConnected) return true;
    return this.svc.bleConnecting || this.svc.wifiAutoConnecting || this.svc.apJoining
      || this.svc.wifiReconnecting || this.svc.wifiConnecting || this.svc.scanning
      || this.svc.disconnecting;
  }

  private toast(message: ResourceStr): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
    } catch (_e) {
      // 页面正在退出时 toast 不可用，不影响状态
    }
  }

  /** 点一行：把它设成当前相机（不主动连接，连接仍由用户到相机页点按钮）。 */
  private onPick(cam: SavedCamera): void {
    if (cam.key === this.cameraStore.currentKey) return;
    if (this.linked()) {
      this.toast($r('app.string.camera_paired_need_disconnect'));
      return;
    }
    if (!this.cameraStore.activate(cam.key)) return;
    this.svc.applySavedCamera(cam);
    this.toast($r('app.string.camera_paired_switched', this.cameraText(cam)));
  }

  private onDelete(cam: SavedCamera): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.camera_paired_delete_title'),
      message: $r('app.string.camera_paired_delete_message'),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.common_cancel'),
        action: () => {}
      },
      secondaryButton: {
        value: $r('app.string.common_delete'),
        fontColor: $r('app.color.button_danger'),
        action: () => {
          if (cam.key === this.cameraStore.currentKey && this.linked()) {
            this.toast($r('app.string.camera_paired_need_disconnect'));
            return;
          }
          const wasCurrent = cam.key === this.cameraStore.currentKey;
          this.cameraStore.remove(cam.key);
          if (!wasCurrent) return;
          // 删的是当前这台：相机页的标题/立牌要跟着换——要么切到回退的那台，
          // 要么回到「相机」。否则标题栏会继续挂着刚删掉的相机的型号与序列号
          // （1.66.1）。
          const cur = this.cameraStore.current();
          if (cur !== null) {
            this.svc.applySavedCamera(cur);
          } else {
            this.svc.applyNewCameraSelection();
          }
        }
      }
    });
  }

  /** 「当前」小胶囊：和相机页照片数、状态头用同一套淡底。 */
  @Builder
  CurrentChip() {
    Text($r('app.string.camera_paired_current'))
      .fontSize(FontSize.Caption)
      .fontColor($r('app.color.primary'))
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .backgroundColor($r('app.color.primary_soft'))
      .borderRadius(Radius.Chip)
      .flexShrink(0)
  }

  /** 「模拟」小胶囊：调试包的虚拟相机必须和真机分得出来。 */
  @Builder
  MockChip() {
    Text($r('app.string.camera_mock_badge'))
      .fontSize(FontSize.Caption)
      .fontColor($r('app.color.text_secondary'))
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .backgroundColor($r('app.color.filter_chip_bg'))
      .borderRadius(Radius.Chip)
      .flexShrink(0)
  }

  /** 左滑出现的删除按钮（官方 List 的 swipeAction，不自己画手势）。 */
  @Builder
  DeleteAction(cam: SavedCamera) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(IconSize.Nav)
        .fontColor([$r('app.color.button_danger')])
    }
    .width(56)
    .height(56)
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(Radius.Card)
    .shadow(CardShadow)
    .margin({ left: 8 })
    .onClick(() => { this.onDelete(cam); })
  }

  @Builder
  CameraRow(cam: SavedCamera) {
    Row({ space: 8 }) {
      Column({ space: 4 }) {
        Text(this.cameraText(cam))
          .fontSize(FontSize.CardTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .alignSelf(ItemAlign.Start)
        Row({ space: 6 }) {
          if (cam.isMock === true) {
            this.MockChip()
          }
          if (cam.key === this.cameraStore.currentKey) {
            this.CurrentChip()
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(IconSize.Body)
        .fontColor([$r('app.color.text_tertiary')])
    }
    .width('100%')
    .padding(16)
    // 有「当前」胶囊的那一行会更高：给一个最小高度，列表里两行一样高
    .constraintSize({ minHeight: 84 })
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(Radius.Card)
    .shadow(CardShadow)
    .onClick(() => { this.onPick(cam); })
  }

  build() {
    NavDestination() {
      Column() {
        PageHeader({
          title: $r('app.string.camera_paired_title'),
          subtitle: L10n.plural('paired_camera_count',
            this.cameraStore.cameras.length, this.cameraStore.cameras.length),
          onBack: () => { this.pageInfos.pop(); }
        })

        if (this.cameraStore.cameras.length === 0) {
          Column({ space: 6 }) {
            Text($r('app.string.camera_paired_empty'))
              .fontSize(FontSize.Body)
              .fontColor($r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 32, right: 32 })
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 8 }) {
            ForEach(this.cameraStore.sorted(), (cam: SavedCamera) => {
              ListItem() {
                this.CameraRow(cam)
              }
              .swipeAction({ end: this.DeleteAction(cam) })
            }, (cam: SavedCamera) => cam.key)

            ListItem() {
              Text($r('app.string.camera_paired_hint'))
                .fontSize(FontSize.Caption)
                .lineHeight(18)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .padding({ left: 4, right: 4, top: 8 })
            }
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 16, right: 16, top: 8 })
          .scrollBar(BarState.Off)
        }
      }
      .width('100%').height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
    })
  }
}
