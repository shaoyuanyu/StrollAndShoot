/**
 * AnimationProperties.ets
 * Shared element ("一镜到底") transition animation encapsulation.
 * Adapted from official HarmonyOS shared element transition sample.
 */
import { curves, UIContext } from '@kit.ArkUI';
import { WindowUtils } from '../utils/WindowUtils';
import { RectInfoInPx } from '../utils/ComponentAttrUtils';
import { MyNodeController } from '../NodeContainer/CustomComponent';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'AnimationProperties';
const DOMAIN = 0xF811;
const DEVICE_BORDER_RADIUS: number = 34;

/**
 * Container for calculated initial transform values.
 */
class InitTransform {
  initScale: number = 1;
  initTranslateX: number = 0;
  initTranslateY: number = 0;
  initClipWidth: Dimension = 0;
  initClipHeight: Dimension = 0;
  initPositionValue: number = 0;
}

@ObservedV2
export class AnimationProperties {
  @Trace navDestinationBgColor: ResourceColor = Color.Transparent;
  @Trace translateX: number = 0;
  @Trace translateY: number = 0;
  @Trace scaleValue: number = 1;
  @Trace clipWidth: Dimension = 0;
  @Trace clipHeight: Dimension = 0;
  @Trace radius: number = 0;
  @Trace positionValue: number = 0;
  @Trace showDetailContent: boolean = false;
  private uiContext: UIContext;

  constructor(uiContext: UIContext) {
    this.uiContext = uiContext;
  }

  /**
   * Calculate thumbnail-position transform values from the card rect.
   * Shared between setInitialState() and doAnimation().
   */
  private calcInitTransform(cardItemInfoPx: RectInfoInPx, extraTranslateValue: number): InitTransform {
    const widthScaleRatio = cardItemInfoPx.width / WindowUtils.windowWidthPx;
    const heightScaleRatio = cardItemInfoPx.height / WindowUtils.windowHeightPx;
    const isUseWidthScale = widthScaleRatio > heightScaleRatio;
    const result = new InitTransform();
    result.initScale = isUseWidthScale ? widthScaleRatio : heightScaleRatio;
    result.initPositionValue = -this.uiContext.px2vp(WindowUtils.topAvoidAreaHeightPx + extraTranslateValue);

    if (isUseWidthScale) {
      result.initTranslateX = this.uiContext.px2vp(cardItemInfoPx.left -
        (WindowUtils.windowWidthPx - cardItemInfoPx.width) / 2);
      // Inner Stack .position() shifts NodeContainer up, so clipHeight is
      // extended by statusBarHeight and translateY compensates for the shift.
      result.initClipWidth = '100%';
      const expandedH: number = (cardItemInfoPx.height) / result.initScale + WindowUtils.topAvoidAreaHeightPx;
      result.initClipHeight = this.uiContext.px2vp(expandedH);
      result.initTranslateY = this.uiContext.px2vp(cardItemInfoPx.top -
        ((expandedH - expandedH * result.initScale) / 2));
    } else {
      result.initClipHeight = '100%';
      const expandedW: number = (cardItemInfoPx.width) / result.initScale + WindowUtils.topAvoidAreaHeightPx;
      result.initClipWidth = this.uiContext.px2vp(expandedW);
      result.initTranslateX = this.uiContext.px2vp(cardItemInfoPx.left -
        (WindowUtils.windowWidthPx / 2 - cardItemInfoPx.width / 2));
      result.initTranslateY = this.uiContext.px2vp(cardItemInfoPx.top -
        (WindowUtils.windowHeightPx - cardItemInfoPx.height) / 2);
    }

    return result;
  }

  /**
   * Set the animation state to the thumbnail position.
   * Call this in onReady (BEFORE first render) so the first frame
   * shows the shared element at the correct starting position.
   */
  setInitialState(cardItemInfoPx: RectInfoInPx, extraTranslateValue: number = 0): void {
    const t: InitTransform = this.calcInitTransform(cardItemInfoPx, extraTranslateValue);
    this.scaleValue = t.initScale;
    this.translateX = t.initTranslateX;
    this.translateY = t.initTranslateY;
    this.clipWidth = t.initClipWidth;
    this.clipHeight = t.initClipHeight;
    this.positionValue = t.initPositionValue;
    hilog.info(DOMAIN, TAG, 'setInitialState: scale=' + t.initScale +
      ' translate=' + t.initTranslateX + ',' + t.initTranslateY);
  }

  /**
   * Run the shared element transition animation.
   *
   * @param cardItemInfoPx  screen-space rect of the thumbnail in the source page
   * @param isPush          true = push operation, false = pop
   * @param isExit          true = this page is exiting, false = this page is entering
   * @param transitionProxy Navigation transition proxy (call finishTransition() when done)
   * @param extraTranslateValue extra vertical offset for status bar compensation
   * @param prePageOnFinish callback to invoke on the source page when pop animation finishes
   * @param myNodeController the NodeController holding the shared element
   */
  doAnimation(cardItemInfoPx: RectInfoInPx, isPush: boolean, isExit: boolean,
    transitionProxy: NavigationTransitionProxy, extraTranslateValue: number,
    prePageOnFinish: (controller: MyNodeController) => void,
    myNodeController: MyNodeController | undefined): void {

    const t: InitTransform = this.calcInitTransform(cardItemInfoPx, extraTranslateValue);
    const initScale = t.initScale;
    const initTranslateX = t.initTranslateX;
    const initTranslateY = t.initTranslateY;
    const initClipWidth: Dimension = t.initClipWidth;
    const initClipHeight: Dimension = t.initClipHeight;
    const initPositionValue = t.initPositionValue;

    hilog.info(DOMAIN, TAG, 'doAnimation: initScale=' + initScale +
      ' translate=' + initTranslateX + ',' + initTranslateY);

    // ---- Push animation: thumbnail position → full screen ----
    if (isPush && !isExit) {
      // Set initial state = thumbnail position
      this.scaleValue = initScale;
      this.translateX = initTranslateX;
      this.translateY = initTranslateY;
      this.clipWidth = initClipWidth;
      this.clipHeight = initClipHeight;
      this.positionValue = initPositionValue;

      // Main spring animation: expand to full screen
      this.uiContext?.animateTo({
        curve: curves.interpolatingSpring(0, 1, 328, 36),
        onFinish: () => {
          if (transitionProxy) {
            transitionProxy.finishTransition();
          }
        }
      }, () => {
        this.scaleValue = 1.0;
        this.translateX = 0;
        this.translateY = 0;
        this.clipWidth = '100%';
        this.clipHeight = '100%';
        this.radius = DEVICE_BORDER_RADIUS;
        this.showDetailContent = true;
      });

      // Background fade animation
      this.uiContext?.animateTo({
        duration: 100,
        curve: Curve.Sharp,
      }, () => {
        this.navDestinationBgColor = '#00ffffff';
      });
    }
    // ---- Pop animation: full screen → thumbnail position ----
    else if (!isPush && isExit) {
      // Animate back to thumbnail position
      this.uiContext?.animateTo({
        duration: 350,
        curve: Curve.EaseInOut,
        onFinish: () => {
          if (transitionProxy) {
            transitionProxy.finishTransition();
          }
          prePageOnFinish(myNodeController);
          // Remove shared element node from this page
          if (myNodeController != undefined) {
            (myNodeController as MyNodeController).onRemove();
          }
        }
      }, () => {
        this.scaleValue = initScale;
        this.translateX = initTranslateX;
        this.translateY = initTranslateY;
        this.radius = 4;
        this.clipWidth = initClipWidth;
        this.clipHeight = initClipHeight;
        this.showDetailContent = false;
      });

      // Background fade back to transparent
      this.uiContext?.animateTo({
        duration: 200,
        delay: 150,
        curve: Curve.Friction,
      }, () => {
        this.navDestinationBgColor = Color.Transparent;
      });
    }
  }
}
