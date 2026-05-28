/**
 * CustomComponent.ets
 * Custom placeholder node with cross-page migration capability (BuilderNode singleton).
 * Adapted from official HarmonyOS shared element transition sample.
 */
import { image } from '@kit.ImageKit';
import { BuilderNode, FrameNode, NodeController, UIContext } from '@kit.ArkUI';

/**
 * Builder function that renders the shared element thumbnail Image.
 * The PixelMap is set dynamically via setPixelMap().
 */
@Builder
function cardBuilder(pm: image.PixelMap) {
  Image(pm)
    .objectFit(ImageFit.Cover)
    .width('100%')
    .height('100%')
    .id('card')
}

export class MyNodeController extends NodeController {
  private cardNode: BuilderNode<[image.PixelMap]> | null = null;
  private wrapBuilder_: WrappedBuilder<[image.PixelMap]> = wrapBuilder(cardBuilder);
  private isRemove: boolean = false;

  makeNode(uiContext: UIContext): FrameNode | null {
    if (this.isRemove === true) {
      return null;
    }
    if (this.cardNode === null) {
      return null;
    }
    return this.cardNode!.getFrameNode()!;
  }

  /**
   * Set (or update) the thumbnail PixelMap to display.
   * Rebuilds the BuilderNode so the new image is rendered.
   */
  setPixelMap(uiContext: UIContext, pm: image.PixelMap): void {
    this.cardNode = new BuilderNode<[image.PixelMap]>(uiContext);
    this.cardNode!.build(this.wrapBuilder_, pm);
    this.isRemove = false;
    this.rebuild();
  }

  /**
   * Remove the node from the current page (prepares it for migration).
   */
  onRemove(): void {
    this.isRemove = true;
    this.rebuild();
    this.isRemove = false;
  }

  /**
   * Clear the node entirely.
   */
  clear(): void {
    this.cardNode = null;
    this.isRemove = true;
    this.rebuild();
  }
}

// Global singleton node controller (cross-page migration)
let myNode: MyNodeController | undefined;

/**
 * Create the global MyNodeController if it doesn't exist yet.
 * Must be called before any page tries to use the shared element.
 */
export const createMyNode = (uiContext: UIContext): void => {
  if (myNode === undefined) {
    myNode = new MyNodeController();
  }
};

/**
 * Get the global MyNodeController singleton.
 */
export const getMyNode = (): MyNodeController | undefined => {
  return myNode;
};
