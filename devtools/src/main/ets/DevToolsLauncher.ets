import { preferences } from '@kit.ArkData';

export interface DevToolsBounds {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

const ICON_SIZE: number = 58;

@ComponentV2
export struct DevToolsLauncher {
  @Require @Param bounds: DevToolsBounds;
  @Event onOpen: () => void = (): void => {};
  @Local private x: number = 0;
  @Local private y: number = 0;
  private side: string = '';
  private topOffset: number = 88;
  private startX: number = 0;
  private startY: number = 0;
  private store?: preferences.Preferences;

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext();
    if (context) {
      try {
        this.store = preferences.getPreferencesSync(context, { name: 'devtools_launcher' });
        const side = this.store.getSync('side', '');
        const y = this.store.getSync('top', 88);
        if (side === 'left' || side === 'right') { this.side = side; }
        if (typeof y === 'number' && Number.isFinite(y)) { this.topOffset = y; }
      } catch { /* The launcher can also be used without preferences. */ }
    }
    this.place();
  }

  @Monitor('bounds')
  place(): void {
    const lastX = Math.max(this.bounds.left, this.bounds.right - ICON_SIZE);
    this.move(this.side === 'left' ? this.bounds.left : (this.side === 'right' ? lastX : lastX - 10),
      this.bounds.top + this.topOffset);
  }

  private move(x: number, y: number): void {
    this.x = Math.max(this.bounds.left, Math.min(x, this.bounds.right - ICON_SIZE));
    this.y = Math.max(this.bounds.top, Math.min(y, this.bounds.bottom - ICON_SIZE));
  }

  private dock(): void {
    this.side = 2 * this.x + ICON_SIZE < this.bounds.left + this.bounds.right ? 'left' : 'right';
    this.topOffset = this.y - this.bounds.top;
    this.getUIContext().animateTo({ duration: 150, curve: Curve.EaseOut }, (): void => this.place());
    try {
      this.store?.putSync('side', this.side);
      this.store?.putSync('top', this.topOffset);
      this.store?.flush().catch((): void => {});
    } catch { /* Keep the current position for this window. */ }
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      Image($r('app.media.devtools_launcher_hammer'))
        .width(44).height(44).objectFit(ImageFit.Contain).draggable(false).accessibilityLevel('no')
    }
    .width(ICON_SIZE).height(ICON_SIZE).padding(0).borderRadius(0)
    .backgroundColor(Color.Transparent).stateEffect(false)
    .position({ x: this.x, y: this.y })
    .accessibilityText('打开开发工具').id('devtools_launcher')
    .onClick((): void => this.onOpen())
    .priorityGesture(PanGesture({ distance: 6 })
      .onActionStart((): void => { this.startX = this.x; this.startY = this.y; })
      .onActionUpdate((event: GestureEvent): void => this.move(this.startX + event.offsetX, this.startY + event.offsetY))
      .onActionEnd((): void => this.dock())
      .onActionCancel((): void => this.place()))
  }
}
