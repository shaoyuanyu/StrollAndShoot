import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'SwiperTest';
const DOMAIN = 0x0001;

const COLORS: string[] = [
  '#FF6B6B', '#FFA94D', '#FFD43B', '#69DB7C', '#4DABF7',
  '#9775FA', '#F783AC', '#63E6BE', '#E599F7', '#FF922B',
];
const TOTAL = COLORS.length;
const DISPLAY_COUNT = 9;
const HALF = Math.floor(DISPLAY_COUNT / 2);
const DISPLAY_TOTAL = TOTAL + HALF * 2;

function buildIndices(): number[] {
  const arr: number[] = [];
  for (let i = 0; i < DISPLAY_TOTAL; i++) { arr.push(i); }
  return arr;
}
const DISPLAY_INDICES = buildIndices();

function isPlaceholder(displayIdx: number): boolean {
  return displayIdx < HALF || displayIdx >= HALF + TOTAL;
}

function toReal(displayIdx: number): number {
  return displayIdx - HALF;
}

@ComponentV2
struct ThumbBlock {
  @Param color: string = '#888';
  @Param label: string = '';
  @Param isPlaceholder: boolean = false;
  @Param s: number = 1.0;
  @Param ox: number = 0;
  @Event onCellClick?: () => void;

  build() {
    Column() {
      Text(this.isPlaceholder ? '' : this.label)
        .fontSize(9).fontColor(Color.White).textAlign(TextAlign.Center)
    }
    .width('100%').aspectRatio(1)
    .borderRadius(4)
    .backgroundColor(this.isPlaceholder ? Color.Transparent : this.color)
    .justifyContent(FlexAlign.Center)
    .offset({ x: this.ox })
    .scale({ x: this.s, y: this.s })
    .animation({ duration: 200, curve: Curve.Linear })
    .onClick(() => { if (!this.isPlaceholder) { this.onCellClick?.(); } })
  }
}

const MAX_S = 1.3;          // center item enlarged
const MIN_S = 1.0;          // non-center items fill slot, no visual gaps
const ITEM_SPACE = 2;       // base layout gap
const CENTER_OFFSET = 14;   // push neighbors away from center
const SNAP_DURATION = 150;  // both swipers snap animation duration (ms)

@Entry
@ComponentV2
struct SwiperSyncTestPage {
  @Local mainIdx: number = 0;
  @Local thumbIdx: number = 0;
  private mainCtrl: SwiperController = new SwiperController();
  private thumbCtrl: SwiperController = new SwiperController();

  // Drag tracking
  private _fromMain: boolean = false;
  private _isDragging: boolean = false;
  private _lastMainFrac: number = 0;
  @Local _swiperWidth: number = 360; // default, updated by onAreaChange
  @Local _thumbItemW: number = 60;
  private _seq: number = 0;
  @Local scaleArr: number[] = [];
  @Local offsetArr: number[] = [];

  aboutToAppear(): void {
    this.scaleArr = new Array(DISPLAY_TOTAL).fill(MIN_S);
    this.offsetArr = new Array(DISPLAY_TOTAL).fill(0);
    if (DISPLAY_TOTAL > HALF) {
      this.scaleArr[HALF] = MAX_S;
      for (let i = 0; i < DISPLAY_TOTAL; i++) {
        if (!isPlaceholder(i) && i !== HALF) {
          this.offsetArr[i] = i > HALF ? CENTER_OFFSET : -CENTER_OFFSET;
        }
      }
    }
  }

  private log(msg: string): void {
    this._seq++;
    hilog.info(DOMAIN, TAG, `[${this._seq}] ${msg}`);
  }

  private updateScales(realFrac: number): void {
    const centerFrac = realFrac + HALF;
    const centerIdx = Math.round(centerFrac);
    for (let i = 0; i < DISPLAY_TOTAL; i++) {
      if (isPlaceholder(i)) {
        this.scaleArr[i] = 0;
        this.offsetArr[i] = 0;
      } else {
        const d = i - centerIdx;
        if (d === 0) {
          this.scaleArr[i] = MAX_S;
          this.offsetArr[i] = 0;
        } else {
          this.scaleArr[i] = MIN_S;
          this.offsetArr[i] = d > 0 ? CENTER_OFFSET : -CENTER_OFFSET;
        }
      }
    }
  }

  // ========== Main → Thumb ==========

  private onMainGestureSwipe(index: number, extraInfo: SwiperAnimationEvent): void {
    if (!this._isDragging && Math.abs(extraInfo.currentOffset) > 0.5) {
      this._fromMain = true;
      this._isDragging = true;
      this._lastMainFrac = this.mainIdx;
      this.thumbCtrl.startFakeDrag();
      this.log(`M-drag start @${this.mainIdx}`);
    }

    if (!this._isDragging) return;

    const mainFrac = index - extraInfo.currentOffset / this._swiperWidth;
    const delta = mainFrac - this._lastMainFrac;
    this._lastMainFrac = mainFrac;
    this.thumbCtrl.fakeDragBy(-delta * (this._thumbItemW + ITEM_SPACE));
    this.updateScales(mainFrac);
  }

  // Track snap animation via onContentDidScroll — uses main's ACTUAL position
  // to drive thumb position, guaranteeing sync regardless of animation duration
  private onMainContentDidScroll(_sel: number, index: number, position: number): void {
    if (!this._isDragging) return;
    // mainIdx is unchanged during snap; use it to filter relevant page events
    if (index !== this.mainIdx) return;
    if (Math.abs(position) < 0.005) return;

    const mainFrac = index - position;
    const delta = mainFrac - this._lastMainFrac;
    this._lastMainFrac = mainFrac;
    this.thumbCtrl.fakeDragBy(-delta * (this._thumbItemW + ITEM_SPACE));
    this.updateScales(mainFrac);
  }

  private onMainAnimationEnd(index: number): void {
    this.log(`M-animEnd @${index}`);
    if (this._isDragging) {
      this.thumbCtrl.stopFakeDrag();
      this._isDragging = false;
    }
    this._fromMain = false;
    this.mainIdx = index;
    this.thumbIdx = index;
    this.thumbCtrl.changeIndex(index, false);
    this.updateScales(index);
  }

  private onMainChange(idx: number): void {
    this.mainIdx = idx;
    if (this._fromMain) {
      this._fromMain = false;
      if (this._isDragging) {
        this.thumbCtrl.stopFakeDrag();
        this._isDragging = false;
      }
      this.thumbIdx = idx;
      this.thumbCtrl.changeIndex(idx, false);
      this.updateScales(idx);
    }
  }

  // ========== Thumb → Main ==========

  private onThumbGestureSwipe(index: number, extraInfo: SwiperAnimationEvent): void {
    if (this._fromMain) return;

    // Compute which real item is at center of thumb strip
    const centerReal = index - extraInfo.currentOffset / (this._thumbItemW + ITEM_SPACE);
    const clamped = Math.max(0, Math.min(Math.round(centerReal), TOTAL - 1));
    if (clamped !== this.mainIdx) {
      this.mainIdx = clamped;
    }
    // Update scales based on current drag position
    this.updateScales(centerReal);
  }

  private onThumbAnimationStart(_index: number, targetIndex: number): void {
    if (this._fromMain) return;
    // targetIndex is the first-visible display index, which equals the center real index
    const realTarget = Math.max(0, Math.min(targetIndex, TOTAL - 1));
    this.mainCtrl.changeIndex(realTarget, true);
  }

  private onThumbAnimationEnd(index: number): void {
    if (this._fromMain) return;
    // index is the first-visible display index, which equals the center real index
    const realIdx = Math.max(0, Math.min(index, TOTAL - 1));
    this.mainIdx = realIdx;
    this.thumbIdx = index;
    this.updateScales(realIdx);
  }

  private onThumbChange(idx: number): void {
    this.thumbIdx = idx;
    if (this._fromMain) return;
    const centerIdx = idx + HALF;
    if (isPlaceholder(centerIdx)) return;
    const realIdx = Math.max(0, Math.min(toReal(centerIdx), TOTAL - 1));
    this.mainIdx = realIdx;
    this.updateScales(realIdx);
  }

  // ========== Click ==========

  private onThumbClick(realIdx: number): void {
    if (realIdx === this.mainIdx) return;
    this.log(`click ${realIdx}`);
    this._fromMain = true;
    // _isDragging stays false — onMainAnimationStart will skip stopFakeDrag
    this.thumbCtrl.changeIndex(realIdx, true);
    this.mainCtrl.changeIndex(realIdx, true);
  }

  // ========== Build ==========

  @Builder
  ThumbCell(displayIdx: number) {
    ThumbBlock({
      color: COLORS[toReal(displayIdx)],
      label: `${toReal(displayIdx)}`,
      isPlaceholder: isPlaceholder(displayIdx),
      s: this.scaleArr[displayIdx] ?? MIN_S,
      ox: this.offsetArr[displayIdx] ?? 0,
      onCellClick: () => { this.onThumbClick(toReal(displayIdx)); }
    })
  }

  build() {
    Column() {
      Row() {
        Button('<-').width(40).height(40).onClick(() => { router.back(); })
        Text(`m:${this.mainIdx} t:${this.thumbIdx} iw:${this._thumbItemW.toFixed(0)} sw:${this._swiperWidth.toFixed(0)}`)
          .fontSize(12).fontColor(Color.White).layoutWeight(1).textAlign(TextAlign.Center)
        Button('X').width(40).height(40)
      }
      .width('100%').height(48).padding({ left: 8, right: 8 }).backgroundColor('#222')

      Stack() {
        // ===== Main Swiper =====
        Swiper(this.mainCtrl) {
          ForEach(COLORS, (color: string, idx: number) => {
            Column() {
              Text(`${idx}`).fontSize(72).fontColor(Color.White)
            }
            .width('100%').height('100%')
            .backgroundColor(color)
            .justifyContent(FlexAlign.Center)
            .onAreaChange((_o: Area, n: Area) => {
              const w = n.width as number;
              if (w > 0) { this._swiperWidth = w; }
            })
          }, (_: string, idx: number) => idx.toString())
        }
        .index(this.mainIdx)
        .onGestureSwipe((i: number, e: SwiperAnimationEvent) => { this.onMainGestureSwipe(i, e); })
        .onContentDidScroll((s: number, i: number, p: number) => { this.onMainContentDidScroll(s, i, p); })
        .onAnimationEnd((i: number) => { this.onMainAnimationEnd(i); })
        .onChange((i: number) => { this.onMainChange(i); })
        .cachedCount(2).loop(false).indicator(false)
        .curve(Curve.Linear).duration(SNAP_DURATION)
        .width('100%').height('100%')

        // ===== Thumb Swiper =====
        Column() {
          Blank()
          Row() {
            Swiper(this.thumbCtrl) {
              ForEach(DISPLAY_INDICES, (displayIdx: number) => {
                this.ThumbCell(displayIdx)
              }, (displayIdx: number) => displayIdx.toString())
            }
            .cachedCount(6)
            .index(this.thumbIdx)
            .displayCount(DISPLAY_COUNT)
            .indicator(false).itemSpace(ITEM_SPACE)
            .width('100%').height(this._thumbItemW).clip(false)
            .disableSwipe(false).loop(false)
            .curve(Curve.Linear).duration(SNAP_DURATION)
            .onGestureSwipe((i: number, e: SwiperAnimationEvent) => { this.onThumbGestureSwipe(i, e); })
            .onAnimationStart((i: number, t: number) => { this.onThumbAnimationStart(i, t); })
            .onAnimationEnd((i: number) => { this.onThumbAnimationEnd(i); })
            .onChange((i: number) => { this.onThumbChange(i); })
            .onAreaChange((_o: Area, n: Area) => {
              const sw = n.width as number;
              this._thumbItemW = (sw - (DISPLAY_COUNT - 1) * ITEM_SPACE) / DISPLAY_COUNT;
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor('rgba(0,0,0,0.7)')
        }
        .width('100%').height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }
      .width('100%').layoutWeight(1)
    }
    .width('100%').height('100%')
    .backgroundColor(Color.Black)
  }
}
