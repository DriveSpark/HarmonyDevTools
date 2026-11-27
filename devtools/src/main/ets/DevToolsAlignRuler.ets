import { UIObserver, uiObserver } from '@kit.ArkUI';
import { DevToolsBounds } from './DevToolsLauncher';
import {
  DEVTOOLS_RULER_MARKER_SIZE, DevToolsRulerDistances, DevToolsRulerGeometry, DevToolsRulerPoint
} from './DevToolsRulerGeometry';

@ComponentV2
export struct DevToolsAlignRuler {
  @Require @Param bounds: DevToolsBounds;
  @Require @Param statusBarHeight: number;
  @Event onClose: () => void = (): void => {};
  @Local private includeStatusBar: boolean = false;
  @Local private markerAnchor?: DevToolsRulerPoint;
  @Local private cardAnchor?: DevToolsRulerPoint;
  @Local private pixelScale: number = 1;
  @Local private hostShortSide: number = 0;
  private markerStart: DevToolsRulerPoint = { x: 0, y: 0 };
  private cardStart: DevToolsRulerPoint = { x: 0, y: 0 };
  private readonly lines: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private linesReady: boolean = false;
  private observer?: UIObserver;
  private readonly densityChanged = (info: uiObserver.DensityInfo): void => {
    if (info.density > 0) { this.pixelScale = info.density; }
  };

  aboutToAppear(): void {
    const ui = this.getUIContext();
    this.pixelScale = ui.vp2px(1);
    if (!this.observer) {
      this.observer = ui.getUIObserver();
      this.observer.on('densityUpdate', this.densityChanged);
    }
  }

  aboutToDisappear(): void {
    this.observer?.off('densityUpdate', this.densityChanged);
    this.observer = undefined;
    this.linesReady = false;
  }

  @Computed private get geometry(): DevToolsRulerGeometry {
    return new DevToolsRulerGeometry(this.bounds, this.hostShortSide);
  }

  @Computed private get marker(): DevToolsRulerPoint {
    return this.geometry.markerPosition(this.markerAnchor);
  }

  @Computed private get card(): DevToolsRulerPoint {
    return this.geometry.cardPosition(this.cardAnchor);
  }

  @Computed private get distances(): DevToolsRulerDistances {
    return this.geometry.distances(this.marker, this.pixelScale, this.includeStatusBar ? this.statusBarHeight : 0);
  }

  @Monitor('marker', 'distances', 'geometry', 'pixelScale')
  drawLines(): void {
    if (!this.linesReady || this.pixelScale <= 0) { return; }
    const ctx = this.lines;
    const w = ctx.width;
    const h = ctx.height;
    const x = this.marker.x;
    const y = this.marker.y;
    const d = this.distances;
    ctx.clearRect(0, 0, w, h);
    ctx.strokeStyle = '#CC3A4B';
    ctx.lineWidth = 1 / this.pixelScale;
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(w, y);
    ctx.moveTo(x, 0);
    ctx.lineTo(x, h);
    ctx.stroke();
    ctx.fillStyle = '#333333';
    ctx.font = `${Math.round(this.getUIContext().fp2px(14))}px sans-serif`;
    ctx.fillText(String(d.left), x / 2, y);
    ctx.fillText(String(d.right), (x + w) / 2, y);
    ctx.fillText(String(d.top), x, y / 2);
    ctx.fillText(String(d.bottom), x, (y + h) / 2);
  }

  private readout(): string {
    const d = this.distances;
    return `位置：左${d.left} 右${d.right} 上${d.top} 下${d.bottom}`;
  }

  private dragMarker(event: GestureEvent): void {
    this.markerAnchor = this.geometry.markerFraction(this.markerStart.x + event.offsetX,
      this.markerStart.y + event.offsetY);
  }

  private dragCard(event: GestureEvent): void {
    this.cardAnchor = this.geometry.cardFraction(this.cardStart.x + event.offsetX,
      this.cardStart.y + event.offsetY, this.cardAnchor);
  }

  @Builder
  markerView() {
    Stack() {
      Row().width(40).height(40).borderRadius(20).backgroundColor('#32CC3A4B')
      Row().width(5).height(5).borderRadius(2.5).backgroundColor('#CC3A4B')
    }
    .width(DEVTOOLS_RULER_MARKER_SIZE).height(DEVTOOLS_RULER_MARKER_SIZE)
    .borderRadius(DEVTOOLS_RULER_MARKER_SIZE / 2).backgroundColor('#64FFFFFF')
    .border({ width: '4px', color: '#64337CC4' })
    .position({ x: this.marker.x - DEVTOOLS_RULER_MARKER_SIZE / 2, y: this.marker.y - DEVTOOLS_RULER_MARKER_SIZE / 2 })
    .gesture(PanGesture({ distance: 1 })
      .onActionStart((event: GestureEvent): void => { this.markerStart = this.marker; this.dragMarker(event); })
      .onActionUpdate((event: GestureEvent): void => this.dragMarker(event))
      .onActionEnd((event: GestureEvent): void => this.dragMarker(event)))
    .accessibilityText('对齐标尺准星').id('devtools_ruler_marker')
  }

  @Builder
  infoCard() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Text(this.readout())
          .width('100%').height('50%').padding({ left: 10, right: 47 })
          .fontSize(14).fontColor('#333333').textAlign(TextAlign.Start).id('devtools_ruler_readout')
        Text('包含状态栏高度')
          .width('100%').height('50%').padding({ left: 10, right: 59 })
          .fontSize(14).fontColor('#333333').textAlign(TextAlign.Start)
      }
      .width('100%').height('100%')
      .gesture(PanGesture({ distance: 3 })
        .onActionStart((event: GestureEvent): void => { this.cardStart = this.card; this.dragCard(event); })
        .onActionUpdate((event: GestureEvent): void => this.dragCard(event))
        .onActionEnd((event: GestureEvent): void => this.dragCard(event)))

      Button({ type: ButtonType.Normal }) {
        Image($r('app.media.devtools_ruler_close')).width(22).height(22).objectFit(ImageFit.Contain).draggable(false)
      }
      .width(22).height(22).padding(0).borderRadius(0).backgroundColor(Color.Transparent).stateEffect(false)
      .position({ x: Math.max(0, this.geometry.cardWidth - 37), y: this.geometry.cardHeight / 4 - 11 })
      .accessibilityText('关闭对齐标尺').id('devtools_ruler_close').onClick((): void => this.onClose())

      Toggle({ type: ToggleType.Button, isOn: this.includeStatusBar }) {
        Image(this.includeStatusBar ? $r('app.media.devtools_switch_on') : $r('app.media.devtools_switch_off'))
          .width(44).height(25).objectFit(ImageFit.Contain).draggable(false)
      }
      .width(44).height(25).padding(0).borderRadius(0)
      .backgroundColor(Color.Transparent).selectedColor(Color.Transparent)
      .position({ x: Math.max(0, this.geometry.cardWidth - 49), y: this.geometry.cardHeight * 0.75 - 12.5 })
      .accessibilityText('包含状态栏高度').accessibilityRole(AccessibilityRoleType.SWITCH).id('devtools_ruler_status')
      .onChange((checked: boolean): void => { this.includeStatusBar = checked; })
    }
    .width(this.geometry.cardWidth).height(this.geometry.cardHeight).position({ x: this.card.x, y: this.card.y })
    .backgroundColor(Color.White).border({ width: '1px', color: '#CCCCCC', radius: 4 }).id('devtools_ruler_card')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.geometry.width > 0 && this.geometry.height > 0) {
        Stack({ alignContent: Alignment.TopStart }) {
          this.markerView()
          Canvas(this.lines)
            .width('100%').height('100%').hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
            .onReady((): void => { this.linesReady = true; this.drawLines(); })
            .onDetach((): void => { this.linesReady = false; })
          this.infoCard()
        }
        .width(this.geometry.width).height(this.geometry.height).position({ x: this.bounds.left, y: this.bounds.top })
        .clip(true).hitTestBehavior(HitTestMode.None).id('devtools_ruler')
      }
    }
    .width('100%').height('100%').hitTestBehavior(HitTestMode.None)
    .onSizeChange((_previous: SizeOptions, current: SizeOptions): void => {
      this.hostShortSide = Math.min(Number(current.width), Number(current.height));
    })
  }
}
