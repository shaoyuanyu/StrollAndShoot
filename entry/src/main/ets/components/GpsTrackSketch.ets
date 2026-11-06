import type { GpsRecord } from '../model/PhotoEntry';
import { type GpsTrackBounds } from '../utils/GpsTrack';
import { WindowUtils } from '../utils/WindowUtils';

/** 归一化后的屏幕坐标（vp，相对本组件左上角）。 */
interface SketchPoint {
  x: number;
  y: number;
}

const EMPTY_BOUNDS: GpsTrackBounds = { minLat: 0, maxLat: 0, minLon: 0, maxLon: 0 };
const START_COLOR: string = '#34C759';
const SELECTED_COLOR: string = '#FF3B30';

/**
 * 无地图时的轨迹示意图。
 *
 * 两个用途：
 * - 地图组件初始化/加载期间的占位，避免展开后先看到一块空白；
 * - 地图服务不可用（模拟器未签名、无网络）时的降级视图，仍然能看出当天走了哪里。
 *
 * 只画 `sketchPoints`（GpsTrack.sample 抽稀到 160 个点），不拿上万个点拼
 * Path 字符串；选中点用完整 bounds 单独归一化，保证和列表是对应的。
 *
 * 用 Canvas 而不是 Shape/Path：Path 的坐标会受 Shape viewPort 二次缩放，
 * 实测 160 个点的折线会被压到左上角；Canvas 的坐标系就是组件 vp，所见即所得。
 */
@ComponentV2
export struct GpsTrackSketch {
  @Param sketchPoints: GpsRecord[] = [];
  @Param bounds: GpsTrackBounds = EMPTY_BOUNDS;
  @Param selected: GpsRecord | null = null;
  @Param caption: string = '';
  /** 说明文字距底部的距离（vp）。全屏页要避开底部明细面板。 */
  @Param captionBottom: number = 10;
  /** 顶部/底部被标题栏、明细面板遮住的高度（vp），用于把轨迹画在真正可见的区域。 */
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Param compact: boolean = false;

  @Local viewWidth: number = 0;
  @Local viewHeight: number = 0;

  private canvasCtx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));

  private chartPadding(): number {
    return this.compact ? 12 : 26;
  }

  private isDark(): boolean {
    return WindowUtils.isDarkMode(this.getUIContext().getHostContext());
  }

  private primaryColor(): string {
    return this.isDark() ? '#4C91FF' : '#0A59F7';
  }

  private casingColor(): string {
    return this.isDark() ? '#CC000000' : '#CCFFFFFF';
  }

  /** 经纬度 → 组件内坐标。经度按纬度做余弦修正，轨迹不会被拉宽。 */
  private pointFor(lat: number, lon: number): SketchPoint {
    const pad = this.chartPadding();
    const visibleH = Math.max(0, this.viewHeight - this.topInset - this.bottomInset);
    const w = Math.max(0, this.viewWidth - pad * 2);
    const h = Math.max(0, visibleH - pad * 2);
    const b = this.bounds;
    const midLat = (b.minLat + b.maxLat) / 2;
    const lonScale = Math.cos(midLat * Math.PI / 180);
    const spanX = (b.maxLon - b.minLon) * lonScale;
    const spanY = b.maxLat - b.minLat;

    if (this.viewWidth <= 0 || this.viewHeight <= 0) {
      return { x: 0, y: 0 };
    }
    if (spanX <= 0 && spanY <= 0) {
      return {
        x: this.viewWidth / 2,
        y: this.topInset + visibleH / 2
      };
    }

    let scale = 0;
    if (spanX > 0 && spanY > 0) {
      scale = Math.min(w / spanX, h / spanY);
    } else if (spanX > 0) {
      scale = w / spanX;
    } else {
      scale = h / spanY;
    }

    const drawW = spanX * scale;
    const drawH = spanY * scale;
    const offX = (this.viewWidth - drawW) / 2;
    const offY = this.topInset + (visibleH - drawH) / 2;
    return {
      x: offX + (lon - b.minLon) * lonScale * scale,
      y: offY + (b.maxLat - lat) * scale
    };
  }

  private layoutPoints(): SketchPoint[] {
    const out: SketchPoint[] = [];
    if (this.viewWidth <= 0 || this.viewHeight <= 0) return out;
    for (let i = 0; i < this.sketchPoints.length; i++) {
      const p = this.sketchPoints[i];
      out.push(this.pointFor(p.latitude, p.longitude));
    }
    return out;
  }

  private fillDot(ctx: CanvasRenderingContext2D, x: number, y: number, r: number,
    color: string): void {
    ctx.beginPath();
    ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.fillStyle = color;
    ctx.fill();
    ctx.lineWidth = 2;
    ctx.strokeStyle = this.casingColor();
    ctx.stroke();
  }

  private draw(): void {
    const w = this.viewWidth;
    const h = this.viewHeight;
    if (w <= 0 || h <= 0) return;

    const ctx = this.canvasCtx;
    ctx.clearRect(0, 0, w, h);

    const points = this.layoutPoints();
    if (points.length > 0) {
      ctx.beginPath();
      ctx.moveTo(points[0].x, points[0].y);
      for (let i = 1; i < points.length; i++) {
        ctx.lineTo(points[i].x, points[i].y);
      }
      ctx.lineCap = 'round';
      ctx.lineJoin = 'round';
      ctx.strokeStyle = this.casingColor();
      ctx.lineWidth = this.compact ? 5 : 7;
      ctx.stroke();
      ctx.strokeStyle = this.primaryColor();
      ctx.lineWidth = this.compact ? 2.5 : 3.5;
      ctx.stroke();

      if (points.length === 1) {
        this.fillDot(ctx, points[0].x, points[0].y, 5, this.primaryColor());
      } else {
        this.fillDot(ctx, points[0].x, points[0].y, 4.5, START_COLOR);
        this.fillDot(ctx, points[points.length - 1].x, points[points.length - 1].y,
          4.5, this.primaryColor());
      }
    }

    if (this.selected !== null) {
      const p = this.pointFor(this.selected.latitude, this.selected.longitude);
      this.fillDot(ctx, p.x, p.y, 6, SELECTED_COLOR);
    }
  }

  @Monitor('sketchPoints')
  onSketchChanged(): void {
    this.draw();
  }

  @Monitor('bounds')
  onBoundsChanged(): void {
    this.draw();
  }

  @Monitor('selected')
  onSelectedChanged(): void {
    this.draw();
  }

  /** 底部面板拖动时可见区域变化，重绘归一化后的轨迹。 */
  @Monitor('bottomInset')
  onBottomInsetChanged(): void {
    this.draw();
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 底色：轻微渐变，和地图的浅色底区分开
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 135,
          colors: [
            [$r('app.color.bg_page'), 0.0],
            [$r('app.color.primary_light'), 1.0]
          ]
        })

      // 淡淡的网格线，暗示这是示意图而不是真实地图
      Column()
        .width('100%').height(1)
        .backgroundColor($r('app.color.divider'))
        .position({ x: 0, y: this.viewHeight * 0.33 })
      Column()
        .width('100%').height(1)
        .backgroundColor($r('app.color.divider'))
        .position({ x: 0, y: this.viewHeight * 0.66 })
      Column()
        .width(1).height('100%')
        .backgroundColor($r('app.color.divider'))
        .position({ x: this.viewWidth * 0.5, y: 0 })

      Canvas(this.canvasCtx)
        .width('100%')
        .height('100%')
        .onReady(() => {
          this.draw();
        })

      if (this.caption.length > 0) {
        Stack({ alignContent: Alignment.BottomStart }) {
          Text(this.caption)
            .fontSize(9)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor($r('app.color.glass_bg'))
            .borderRadius(10)
            .margin({ left: 10, bottom: this.captionBottom })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .onAreaChange((_o: Area, n: Area) => {
      this.viewWidth = n.width as number;
      this.viewHeight = n.height as number;
      this.draw();
    })
  }
}
