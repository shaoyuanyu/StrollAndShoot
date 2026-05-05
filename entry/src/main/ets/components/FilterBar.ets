interface FilterOption {
  label: string;
  value: number;
}

@Component
export struct FilterBar {
  @Prop filterFormat: number = 0;
  onChange: (value: number) => void = (_v: number) => {};

  private options: FilterOption[] = [
    { label: '全部', value: 0 },
    { label: 'JPEG', value: 1 },
    { label: 'RAW', value: 2 },
    { label: 'HEIF', value: 3 }
  ];

  build() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.options, (opt: FilterOption) => {
          Text(opt.label)
            .fontSize(13)
            .fontColor(this.filterFormat === opt.value
              ? $r('app.color.filter_chip_active_text')
              : $r('app.color.filter_chip_text'))
            .backgroundColor(this.filterFormat === opt.value
              ? $r('app.color.filter_chip_active_bg')
              : $r('app.color.filter_chip_bg'))
            .borderRadius(16)
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .onClick(() => { this.onChange(opt.value); })
        })
      }
      .padding({ left: 4, right: 4 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
  }
}
