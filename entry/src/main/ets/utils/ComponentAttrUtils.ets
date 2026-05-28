import { componentUtils, UIContext } from '@kit.ArkUI';

export class RectInfoInPx {
  public left: number = 0;
  public top: number = 0;
  public right: number = 0;
  public bottom: number = 0;
  public width: number = 0;
  public height: number = 0;
}

export class ComponentAttrUtils {
  /**
   * Get the screen-space bounding rect of a component by its ID.
   * Accounts for translate, window offset, and scale.
   */
  public static getRectInfoById(context: UIContext, id: string): RectInfoInPx {
    if (!context || !id) {
      throw new Error('object is empty');
    }
    const componentInfo: componentUtils.ComponentInfo = context.getComponentUtils().getRectangleById(id);

    if (!componentInfo) {
      throw new Error('object is empty');
    }

    const rstRect: RectInfoInPx = new RectInfoInPx();
    const widthScaleGap = componentInfo.size.width * (1 - componentInfo.scale.x) / 2;
    const heightScaleGap = componentInfo.size.height * (1 - componentInfo.scale.y) / 2;
    rstRect.left = componentInfo.translate.x + componentInfo.windowOffset.x + widthScaleGap;
    rstRect.top = componentInfo.translate.y + componentInfo.windowOffset.y + heightScaleGap;
    rstRect.right =
      componentInfo.translate.x + componentInfo.windowOffset.x + componentInfo.size.width - widthScaleGap;
    rstRect.bottom =
      componentInfo.translate.y + componentInfo.windowOffset.y + componentInfo.size.height - heightScaleGap;
    rstRect.width = rstRect.right - rstRect.left;
    rstRect.height = rstRect.bottom - rstRect.top;
    return {
      left: rstRect.left,
      right: rstRect.right,
      top: rstRect.top,
      bottom: rstRect.bottom,
      width: rstRect.width,
      height: rstRect.height
    }
  }
}
