/**
 * 全局 UI 设计令牌。
 *
 * 目的：字号、圆角、行高、图标尺寸不再由各页面手写数字，统一从这里取值，
 * 避免同一语义在不同页面出现 15/16/17、16/18/24 这类漂移。
 *
 * 约定：
 * - 字号按“角色”取值，不按页面取值；
 * - 胶囊/圆形按钮的圆角一律取高度的一半（pillRadius），不要写死；
 * - 卡片 24、卡内嵌块 18、小胶囊 12 是仅有的三档静态圆角。
 */
export class FontSize {
  /** 一级页大标题（画廊 / 相机 / 设置）。 */
  static readonly Display: number = 28;
  /** 多选标题、半模态面板标题。 */
  static readonly Title: number = 22;
  /** 二级页标题。 */
  static readonly PageTitle: number = 20;
  /** 卡片标题、列表行标题、日期分组标题。 */
  static readonly CardTitle: number = 16;
  /** 正文、值、大号操作按钮。 */
  static readonly Body: number = 15;
  /** 分组标题、辅助操作。 */
  static readonly Section: number = 13;
  /** 副标题、说明、小号胶囊按钮。 */
  static readonly Caption: number = 12;
  /** 页签文字、最小标签。 */
  static readonly Micro: number = 10;
  /** 角标（标题栏型号右下角的序列号这类「铭牌」信息）。 */
  static readonly Nano: number = 9;
}

export class IconSize {
  /** 勾选、地图小图标。 */
  static readonly Small: number = 12;
  /** 箭头、行尾图标。 */
  static readonly Body: number = 16;
  /** 标题栏圆形按钮、返回键。 */
  static readonly Nav: number = 20;
  /** 底部页签、多选操作栏。 */
  static readonly Large: number = 24;
  /** 空态大图标。 */
  static readonly Empty: number = 44;
}

export class Radius {
  /** 主卡片。 */
  static readonly Card: number = 24;
  /** 卡内嵌块（地图容器、分组卡、选中行）。 */
  static readonly Inner: number = 18;
  /** 小胶囊、玻璃小标签、调试日志框。 */
  static readonly Chip: number = 12;
  /** 预览器缩略图。 */
  static readonly Thumb: number = 4;
  /** 1vp 级细线/分隔线的端帽。 */
  static readonly Line: number = 1;
}

export class RowHeight {
  /** 单行列表项。 */
  static readonly Single: number = 56;
  /** 双行列表项（标题 + 副标题）。 */
  static readonly Double: number = 64;
}

/** 与圆角配套的固定控件高度。 */
export class ControlHeight {
  /** 标题栏玻璃胶囊、Select。 */
  static readonly Pill: number = 40;
  /** 底部页签、多选操作栏。 */
  static readonly Bar: number = 56;
}

/** 胶囊/圆形按钮的圆角：始终取高度的一半。 */
export function pillRadius(height: number): number {
  return height / 2;
}

/**
 * 页面卡片的投影。
 *
 * 深色下卡片（`#1C1C1E`）压在纯黑页面上，亮度差 28，自己就浮得起来；浅色下
 * 白卡压在 `#F1F3F5` 上，差值只有 13，整页会「发平」——这层极淡的投影
 * （6% 黑、18 模糊、下移 5）补的就是这个差。深色下黑投影落在纯黑背景上看不见，
 * 所以不需要按主题分支。
 *
 * 只加在 24vp 圆角的页面卡片上；卡内的分隔线、行、控件不要再叠。
 */
export const CardShadow: ShadowOptions = {
  radius: 18,
  color: '#0F000000',
  offsetX: 0,
  offsetY: 5
};
