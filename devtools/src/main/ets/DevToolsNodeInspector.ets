import { FrameNode, UIContext, UIObserver } from '@kit.ArkUI';
import { DevToolsBounds } from './DevToolsLauncher';
import { describeDevToolsNode } from './DevToolsNodeDetails';
import {
  cycleDevToolsNodeHit, DevToolsInspectorNode, DevToolsInspectorViewport, DevToolsNodeSnapshot, DevToolsNodeTraits,
  findDevToolsNodeHits, localDevToolsNodeRect, readDevToolsNodeTree, sameDevToolsNodeRect, sameDevToolsNodeTree
} from './DevToolsNodeTree';

export type DevToolsNodeMode = 'inspector' | 'borders';

function currentFrame(ui: UIContext, id: number): FrameNode | null {
  const frame = ui.getFrameNodeByUniqueId(id);
  return frame && !frame.isDisposed() && frame.getUniqueId() === id ? frame : null;
}

function frameTraits(ui: UIContext, id: number): DevToolsNodeTraits | undefined {
  try {
    const frame = currentFrame(ui, id);
    if (frame) {
      return { visible: frame.isAttached() && frame.isVisible() && frame.getOpacity() > 0, clipsChildren: frame.isClipToFrame() };
    }
  } catch { /* A virtualized or unmounted node may disappear while its old snapshot is being inspected. */ }
  return undefined;
}

function inspectorStatus(snapshot: DevToolsNodeSnapshot): string {
  switch (snapshot.status) {
    case 'oversized': return '控件树过大，无法显示';
    case 'unavailable': return '无法读取当前窗口的控件树';
    case 'partial': return '控件较多，仅显示部分节点';
    default: return '';
  }
}

function clampFraction(n: number): number {
  return Math.max(0, Math.min(1, n));
}

@ComponentV2
export struct DevToolsNodeInspector {
  @Require @Param mode: DevToolsNodeMode;
  @Require @Param bounds: DevToolsBounds;
  @Event onClose: () => void = (): void => {};
  @Local private aimFractionX: number = -1;
  @Local private aimFractionY: number = -1;
  @Local private cardFractionX: number = 0.5;
  @Local private cardFractionY: number = 0.95;
  @Local private titleText: string = '控件检查';
  @Local private detailsText: string = '';
  @Local private statusText: string = '';
  @Local private hitCount: number = 0;
  @Local private hitIndex: number = -1;

  private readonly drawing: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private canvasReady: boolean = false;
  private observer?: UIObserver;
  private mounted: boolean = false;
  private hostArea?: Area;
  private pendingRead: number = -1;
  private nextReadAt: number = 0;
  private dragging: boolean = false;
  private cardStartX: number = 0;
  private cardStartY: number = 0;
  private viewport: DevToolsInspectorViewport = { windowX: 0, windowY: 0, width: 0, height: 0, density: 1 };
  private snapshot: DevToolsNodeSnapshot = { nodes: [], status: 'ready' };
  private hits: DevToolsInspectorNode[] = [];
  private readonly windowDraw = (): void => this.scheduleRead();

  aboutToAppear(): void {
    this.mounted = true;
    this.observer = this.getUIContext().getUIObserver();
    this.observer.on('willDraw', this.windowDraw);
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.observer?.off('willDraw', this.windowDraw);
    this.observer = undefined;
    clearTimeout(this.pendingRead);
    this.pendingRead = -1;
    this.canvasReady = false;
    this.hostArea = undefined;
    this.hits = [];
    this.snapshot = { nodes: [], status: 'ready' };
  }

  private get safeWidth(): number { return Math.max(0, this.bounds.right - this.bounds.left); }
  private get safeHeight(): number { return Math.max(0, this.bounds.bottom - this.bounds.top); }
  private get aimX(): number {
    const offset = this.aimFractionX < 0 ? this.safeWidth / 2 + 30 : this.safeWidth * this.aimFractionX;
    return this.bounds.left + Math.max(0, Math.min(offset, this.safeWidth - 0.001));
  }
  private get aimY(): number {
    const offset = this.aimFractionY < 0 ? this.safeHeight / 2 + 30 : this.safeHeight * this.aimFractionY;
    return this.bounds.top + Math.max(0, Math.min(offset, this.safeHeight - 0.001));
  }
  private get cardWidth(): number {
    return Math.min(380, Math.max(this.safeWidth - 30, Math.min(120, this.safeWidth)));
  }
  private get cardHeight(): number { return Math.min(this.safeHeight, this.detailsText ? 174 : 82); }
  private get cardX(): number { return this.bounds.left + (this.safeWidth - this.cardWidth) * this.cardFractionX; }
  private get cardY(): number { return this.bounds.top + (this.safeHeight - this.cardHeight) * this.cardFractionY; }

  @Monitor('mode', 'bounds')
  inputsChanged(): void {
    if (this.mounted) {
      this.updateHits(false, true);
      this.paint();
      this.scheduleRead();
    }
  }

  private scheduleRead(): void {
    if (!this.mounted || !this.hostArea || this.dragging || this.pendingRead !== -1) { return; }
    this.pendingRead = setTimeout((): void => {
      this.pendingRead = -1;
      if (this.mounted && !this.dragging) { this.readWindow(); }
    }, Math.max(0, this.nextReadAt - Date.now()));
  }

  private readWindow(): void {
    const area = this.hostArea;
    if (!area || Number(area.width) <= 0 || Number(area.height) <= 0) { return; }
    const start = Date.now();
    const ui = this.getUIContext();
    let tree: DevToolsNodeSnapshot = { nodes: [], status: 'unavailable' };
    const viewport: DevToolsInspectorViewport = {
      windowX: Number(area.globalPosition.x ?? 0), windowY: Number(area.globalPosition.y ?? 0),
      width: Number(area.width), height: Number(area.height), density: ui.vp2px(1)
    };
    try {
      const overlay = ui.getFrameNodeById('devtools_overlay');
      let excludedId = -1;
      if (overlay && !overlay.isDisposed()) {
        // Inspector rectangles include drawing transforms. Read the overlay origin in the same window space.
        const origin = overlay.getPositionToWindowWithTransform();
        viewport.windowX = origin.x;
        viewport.windowY = origin.y;
        excludedId = overlay.getUniqueId();
      }
      tree = readDevToolsNodeTree(ui.getFilteredInspectorTree(['id']), viewport, excludedId,
        (id: number): DevToolsNodeTraits | undefined => frameTraits(ui, id));
    } catch { /* A closing or protected window may not expose a tree. Remove its previous geometry. */ }
    const previous = this.viewport;
    const moved = viewport.windowX !== previous.windowX || viewport.windowY !== previous.windowY ||
      viewport.width !== previous.width || viewport.height !== previous.height || viewport.density !== previous.density;
    this.viewport = viewport;
    this.nextReadAt = Date.now() + Math.max(350, Math.min(2500, (Date.now() - start) * 6));
    if (moved || !sameDevToolsNodeTree(this.snapshot, tree)) {
      this.snapshot = tree;
      this.statusText = inspectorStatus(tree);
      this.updateHits(true, !this.dragging);
      this.paint();
    }
  }

  private updateHits(preserve: boolean, queryStyle: boolean): void {
    if (this.mode !== 'inspector') { return; }
    const oldId = preserve && this.hitIndex >= 0 ? this.hits[this.hitIndex]?.uniqueId : undefined;
    this.hits = findDevToolsNodeHits(this.snapshot, this.viewport, this.aimX, this.aimY);
    this.hitCount = this.hits.length;
    const previous = oldId === undefined ? -1 : this.hits.findIndex((node: DevToolsInspectorNode): boolean => node.uniqueId === oldId);
    this.hitIndex = this.hitCount ? Math.max(0, previous) : -1;
    this.describeSelection(queryStyle);
  }

  private describeSelection(queryStyle: boolean): void {
    const selected = this.hits[this.hitIndex];
    if (!selected) {
      this.titleText = this.statusText ? '控件检查' : '未命中控件';
      this.detailsText = '';
      return;
    }
    this.titleText = '控件类型：' + selected.componentType;
    let frame: FrameNode | null = null;
    if (queryStyle) {
      try { frame = currentFrame(this.getUIContext(), selected.uniqueId); } catch { /* The snapshot still has its rectangle. */ }
    }
    this.detailsText = describeDevToolsNode(selected, frame);
  }

  private advance(direction: number): void {
    this.hitIndex = cycleDevToolsNodeHit(this.hitIndex, this.hitCount, direction);
    this.describeSelection(true);
    this.paint();
  }

  private touchSurface(event: TouchEvent): void {
    const point = event.changedTouches[0] ?? event.touches[0];
    if (!point || this.safeWidth <= 0 || this.safeHeight <= 0) { return; }
    this.dragging = event.type === TouchType.Down || event.type === TouchType.Move;
    if (event.type !== TouchType.Cancel) {
      this.aimFractionX = clampFraction((point.x - this.bounds.left) / this.safeWidth);
      this.aimFractionY = clampFraction((point.y - this.bounds.top) / this.safeHeight);
    }
    this.updateHits(false, !this.dragging);
    this.paint();
    if (!this.dragging) { this.scheduleRead(); }
  }

  private paintNode(node: DevToolsInspectorNode): void {
    const ctx = this.drawing;
    const rect = localDevToolsNodeRect(node.rect, this.viewport);
    const clipped = !sameDevToolsNodeRect(node.rect, node.visibleRect);
    if (clipped) {
      const visible = localDevToolsNodeRect(node.visibleRect, this.viewport);
      ctx.save();
      ctx.beginPath();
      ctx.rect(visible.left, visible.top, visible.right - visible.left, visible.bottom - visible.top);
      ctx.clip();
    }
    ctx.strokeRect(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top);
    if (clipped) { ctx.restore(); }
  }

  private paint(): void {
    if (!this.canvasReady) { return; }
    const ctx = this.drawing;
    ctx.clearRect(0, 0, ctx.width, ctx.height);
    const line = 4 / this.viewport.density;
    ctx.strokeStyle = '#FF0000';
    ctx.lineWidth = line;
    ctx.setLineDash([line, line]);
    if (this.mode === 'borders') {
      for (const node of this.snapshot.nodes) { this.paintNode(node); }
    } else {
      const node = this.hits[this.hitIndex];
      if (node) { this.paintNode(node); }
    }
  }

  private dragCard(event: GestureEvent): void {
    const horizontal = this.safeWidth - this.cardWidth;
    const vertical = this.safeHeight - this.cardHeight;
    if (horizontal > 0) { this.cardFractionX = clampFraction((this.cardStartX + event.offsetX - this.bounds.left) / horizontal); }
    if (vertical > 0) { this.cardFractionY = clampFraction((this.cardStartY + event.offsetY - this.bounds.top) / vertical); }
  }

  @Builder
  selectionArrow(previous: boolean) {
    Button({ type: ButtonType.Normal }) {
      Image($r('app.media.devtools_chevron')).width(10).height(17).objectFit(ImageFit.Contain).draggable(false)
        .rotate({ angle: previous ? 180 : 0 })
    }
    .width(33).height(38).padding(0).backgroundColor(Color.Transparent).stateEffect(false)
    .accessibilityText(previous ? '上一个重叠控件' : '下一个重叠控件')
    .id(previous ? 'devtools_inspector_previous' : 'devtools_inspector_next')
    .onClick((): void => this.advance(previous ? -1 : 1))
  }

  @Builder
  inspectorCard() {
    Column() {
      Row() {
        Text(this.titleText).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#333333').layoutWeight(1)
          .maxLines(2).id('devtools_inspector_type').height('100%')
          .gesture(PanGesture({ distance: 3 })
            .onActionStart((event: GestureEvent): void => {
              this.cardStartX = this.cardX; this.cardStartY = this.cardY; this.dragCard(event);
            }).onActionUpdate((event: GestureEvent): void => this.dragCard(event)))
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.devtools_ruler_close')).width(22).height(22).objectFit(ImageFit.Contain).draggable(false)
        }.width(36).height(36).padding(0).backgroundColor(Color.Transparent).stateEffect(false)
        .accessibilityText('关闭控件检查').id('devtools_inspector_close').onClick((): void => this.onClose())
      }.width('100%').height(40)
      Row() {
        if (this.hitCount > 1) { this.selectionArrow(true) }
        Scroll() {
          Column({ space: 3 }) {
            if (this.detailsText) {
              Text(this.detailsText).width('100%').fontSize(13).lineHeight(19).fontColor('#333333').id('devtools_inspector_details')
            }
            if (this.hitCount > 1) {
              Text(String(this.hitIndex + 1) + ' / ' + this.hitCount).fontSize(12).fontColor('#666666').id('devtools_inspector_count')
            }
            if (this.statusText) { Text(this.statusText).fontSize(12).fontColor('#666666') }
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.layoutWeight(1).height('100%').align(Alignment.TopStart).scrollBar(BarState.Auto)
        if (this.hitCount > 1) { this.selectionArrow(false) }
      }.width('100%').layoutWeight(1)
    }.width(this.cardWidth).height(this.cardHeight).padding({ left: 10, right: 6, bottom: 7 })
    .backgroundColor(Color.White).border({ width: '1px', color: '#CCCCCC', radius: 4 })
    .position({ x: this.cardX, y: this.cardY }).id('devtools_inspector_card')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Canvas(this.drawing).width('100%').height('100%').hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
        .onReady((): void => { this.canvasReady = true; this.paint(); this.scheduleRead(); })
        .onDetach((): void => { this.canvasReady = false; })
        .id(this.mode === 'borders' ? 'devtools_borders_canvas' : 'devtools_inspector_canvas')
      if (this.mode === 'inspector') {
        Row().width('100%').height('100%').onTouch((event: TouchEvent): void => this.touchSurface(event))
          .id('devtools_inspector_surface')
        Stack() {
          Row().width(40).height(40).borderRadius(20).backgroundColor('#32CC3A4B').hitTestBehavior(HitTestMode.None)
          Row().width(5).height(5).borderRadius(3).backgroundColor('#CC3A4B').hitTestBehavior(HitTestMode.None)
        }.width(60).height(60).borderRadius(30).backgroundColor('#64FFFFFF').border({ width: '4px', color: '#64337CC4' })
        .position({ x: this.aimX - 30, y: this.aimY - 30 }).hitTestBehavior(HitTestMode.None).id('devtools_inspector_marker')
        this.inspectorCard()
      } else {
        Column() {
          Button('关闭布局边框').height(34).fontSize(13).fontColor(Color.White).backgroundColor('#DB30353B')
            .accessibilityText('关闭布局边框').id('devtools_borders_close').onClick((): void => this.onClose())
          if (this.statusText) {
            Text(this.statusText).padding(4).fontSize(12).fontColor(Color.White).backgroundColor('#DB30353B')
              .hitTestBehavior(HitTestMode.None)
          }
        }.width(Math.min(this.safeWidth, 140)).alignItems(HorizontalAlign.End)
        .position({ x: Math.max(this.bounds.left, this.bounds.right - 146), y: this.bounds.top + 6 })
        .hitTestBehavior(HitTestMode.None)
      }
    }.width('100%').height('100%').clip(true).hitTestBehavior(HitTestMode.None)
    .id(this.mode === 'borders' ? 'devtools_borders' : 'devtools_inspector')
    .onAreaChange((_old: Area, current: Area): void => { this.hostArea = current; this.scheduleRead(); })
  }
}
