/**
 * CustomNavigationUtils.ets
 * Navigation custom transition animation registry.
 * Adapted from official HarmonyOS shared element transition sample.
 */

export interface AnimateCallback {
  animation: ((isPush: boolean, isExit: boolean, transitionProxy: NavigationTransitionProxy) => void | undefined) | undefined;
  timeout: (number | undefined) | undefined;
}

const customTransitionMap: Map<number, AnimateCallback> = new Map();

export class CustomTransition {
  private constructor() {
  };

  static delegate = new CustomTransition();

  static getInstance(): CustomTransition {
    return CustomTransition.delegate;
  }

  /**
   * Register an animation callback for a page.
   * @param name page index in the NavPathStack
   * @param animationCallback callback invoked when the transition runs
   * @param timeout transition timeout in ms
   */
  registerNavParam(
    name: number,
    animationCallback: (operation: boolean, isExit: boolean, transitionProxy: NavigationTransitionProxy) => void,
    timeout: number): void {
    if (customTransitionMap.has(name)) {
      const param = customTransitionMap.get(name);
      if (param != undefined) {
        param.animation = animationCallback;
        param.timeout = timeout;
        return;
      }
    }
    const params: AnimateCallback = { timeout: timeout, animation: animationCallback };
    customTransitionMap.set(name, params);
  }

  unRegisterNavParam(name: number): void {
    customTransitionMap.delete(name);
  }

  getAnimateParam(name: number): AnimateCallback {
    const result: AnimateCallback = {
      animation: customTransitionMap.get(name)?.animation,
      timeout: customTransitionMap.get(name)?.timeout,
    };
    return result;
  }
}
