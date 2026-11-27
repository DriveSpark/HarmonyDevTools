import { FrameCallback, UIContext, window } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { DevToolsBounds } from './DevToolsLauncher';

const LENS = 88;
const GRID = 11;

class PickerFrame extends FrameCallback {
  private readonly callback: () => void;
  constructor(callback: () => void) {
    super();
    this.callback = callback;
  }
  onFrame(_time: number): void { this.callback(); }
}

function nextFrame(ui: UIContext): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    ui.postFrameCallback(new PickerFrame(resolve));
  });
}

function hexByte(byte: number): string {
  return byte.toString(16).padStart(2, '0').toUpperCase();
}

@ComponentV2
export struct DevToolsColorPicker {
  @Require @Param bounds: DevToolsBounds;
  @Event onCapturing: (hidden: boolean) => void = (): void => {};
  @Event onClose: () => void = (): void => {};
  @Local private x: number = 0;
  @Local private y: number = 0;
  @Local private hex: string = '';
  @Local private coordinate: string = '';
  @Local private error: string = '';
  @Local private pixels?: image.PixelMap;
  @Local private frameWidth: number = 0;
  @Local private frameHeight: number = 0;
  @Local private originX: number = 0;
  @Local private originY: number = 0;
  private scaleX: number = 1;
  private scaleY: number = 1;
  private widthPx: number = 0;
  private heightPx: number = 0;
  private regionColors: string[] = [];
  private alive: boolean = false;
  private capturing: boolean = false;
  private reading: boolean = false;
  private sampleNumber: number = 0;
  private readonly lens: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(false));

  aboutToAppear(): void {
    this.alive = true;
    this.x = (this.bounds.left + this.bounds.right) / 2;
    this.y = (this.bounds.top + this.bounds.bottom) / 2;
    this.capture();
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.sampleNumber++;
    this.onCapturing(false);
    const old = this.pixels;
    this.pixels = undefined;
    old?.release().catch((): void => {});
  }

  @Monitor('bounds')
  resized(): void {
    this.move(this.x, this.y);
    if (this.alive) { this.capture(); }
  }

  private move(x: number, y: number): void {
    this.x = Math.max(this.bounds.left, Math.min(x, this.bounds.right - 1));
    this.y = Math.max(this.bounds.top, Math.min(y, this.bounds.bottom - 1));
    this.sampleNumber++;
    if (!this.reading && !this.capturing) { this.sample(); }
  }

  private async capture(): Promise<void> {
    if (this.capturing || !this.alive) { return; }
    this.capturing = true;
    this.sampleNumber++;
    this.onCapturing(true);
    let captured: image.PixelMap | undefined;
    try {
      const ui = this.getUIContext();
      // The first VSync applies opacity to the entire toolkit. Sample after the next commit.
      await nextFrame(ui);
      if (!this.alive) { return; }
      await nextFrame(ui);
      if (!this.alive) { return; }
      const host = window.findWindow(ui.getWindowName());
      const props = host.getWindowProperties();
      if (props.isPrivacyMode) { throw new Error('protected'); }
      const offset = ui.getComponentUtils().getRectangleById('devtools_picker').windowOffset;
      captured = await host.snapshot();
      const info = await captured.getImageInfo();
      if (!this.alive) { return; }
      if (host.getWindowProperties().isPrivacyMode || info.size.width <= 0 || info.size.height <= 0) {
        throw new Error('unavailable');
      }
      const old = this.pixels;
      this.widthPx = info.size.width;
      this.heightPx = info.size.height;
      this.frameWidth = ui.px2vp(props.windowRect.width);
      this.frameHeight = ui.px2vp(props.windowRect.height);
      this.originX = ui.px2vp(offset.x);
      this.originY = ui.px2vp(offset.y);
      this.scaleX = this.widthPx / this.frameWidth;
      this.scaleY = this.heightPx / this.frameHeight;
      this.pixels = captured;
      captured = undefined;
      old?.release().catch((): void => {});
      this.error = '';
    } catch {
      if (this.alive) {
        const old = this.pixels;
        this.pixels = undefined;
        old?.release().catch((): void => {});
        this.error = '当前窗口无法取色，可能受隐私保护';
        this.hex = '';
        this.coordinate = '';
        this.regionColors = [];
        this.drawLens();
      }
    } finally {
      captured?.release().catch((): void => {});
      this.capturing = false;
      if (this.alive) {
        this.onCapturing(false);
        this.sampleNumber++;
        if (!this.reading) { this.sample(); }
      }
    }
  }

  private async sample(): Promise<void> {
    const frame = this.pixels;
    if (!frame || !this.alive || this.capturing || this.reading) { return; }
    this.reading = true;
    const version = this.sampleNumber;
    try {
      const px = Math.max(0, Math.min(this.widthPx - 1, Math.floor((this.originX + this.x) * this.scaleX)));
      const py = Math.max(0, Math.min(this.heightPx - 1, Math.floor((this.originY + this.y) * this.scaleY)));
      const half = Math.floor(GRID / 2);
      const left = Math.max(0, px - half);
      const top = Math.max(0, py - half);
      const width = Math.min(this.widthPx, px + half + 1) - left;
      const height = Math.min(this.heightPx, py + half + 1) - top;
      const buffer = new ArrayBuffer(width * height * 4);
      await frame.readPixels({ pixels: buffer, offset: 0, stride: width * 4,
        region: { x: left, y: top, size: { width: width, height: height } } });
      if (!this.alive || version !== this.sampleNumber || frame !== this.pixels) { return; }
      // PixelMap.readPixels(PositionArea) exports BGRA_8888 independently of the source pixel format.
      const bytes = new Uint8Array(buffer);
      const colors: string[] = [];
      for (let row = 0; row < GRID; row++) {
        for (let col = 0; col < GRID; col++) {
          const ix = Math.max(0, Math.min(width - 1, px - left + col - half));
          const iy = Math.max(0, Math.min(height - 1, py - top + row - half));
          const idx = (iy * width + ix) * 4;
          colors.push('#' + hexByte(bytes[idx + 2]) + hexByte(bytes[idx + 1]) + hexByte(bytes[idx]));
        }
      }
      this.regionColors = colors;
      this.hex = colors[half * GRID + half];
      this.coordinate = px + ', ' + py + ' px';
      this.error = '';
      this.drawLens();
    } catch {
      if (this.alive && frame === this.pixels && version === this.sampleNumber) {
        this.error = '像素读取失败，请重新取样';
        this.hex = '';
        this.coordinate = '';
        this.regionColors = [];
        this.drawLens();
      }
    } finally {
      this.reading = false;
      if (this.alive && version !== this.sampleNumber) { this.sample(); }
    }
  }

  private drawLens(): void {
    const side = LENS / GRID;
    const ctx = this.lens;
    ctx.clearRect(0, 0, LENS, LENS);
    for (let i = 0; i < this.regionColors.length; i++) {
      ctx.fillStyle = this.regionColors[i];
      ctx.fillRect((i % GRID) * side, Math.floor(i / GRID) * side, side, side);
    }
    const center = Math.floor(GRID / 2) * side;
    ctx.strokeStyle = '#FFFFFF';
    ctx.lineWidth = 3;
    ctx.strokeRect(center, center, side, side);
    ctx.strokeStyle = '#222222';
    ctx.lineWidth = 1;
    ctx.strokeRect(center, center, side, side);
  }

  private touch(event: TouchEvent): void {
    const finger = event.touches[0] ?? event.changedTouches[0];
    if (finger && (event.type === TouchType.Down || event.type === TouchType.Move)) {
      this.move(finger.x, finger.y);
      if (event.type === TouchType.Down) { this.capture(); }
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.pixels) {
        Image(this.pixels).width(this.frameWidth).height(this.frameHeight).objectFit(ImageFit.Fill)
          .position({ x: -this.originX, y: -this.originY }).hitTestBehavior(HitTestMode.None)
      }
      Row().width('100%').height('100%').onTouch((event: TouchEvent): void => this.touch(event))
        .id('devtools_picker_surface')
      Stack() {
        Row().width(31).height(3).backgroundColor(Color.White)
        Row().width(3).height(31).backgroundColor(Color.White)
        Row().width(31).height(1).backgroundColor('#303030')
        Row().width(1).height(31).backgroundColor('#303030')
      }.width(31).height(31).position({ x: this.x - 15.5, y: this.y - 15.5 })
      .hitTestBehavior(HitTestMode.None)
      Row({ space: 10 }) {
        Canvas(this.lens).width(LENS).height(LENS).borderRadius(LENS / 2).clip(true)
          .border({ color: this.hex || '#FFFFFF', width: 2, radius: LENS / 2 })
          .onReady((): void => this.drawLens()).id('devtools_picker_lens')
        Column({ space: 3 }) {
          Text(this.error || this.hex || '正在取色…').fontSize(this.error ? 13 : 19).fontWeight(FontWeight.Medium)
            .fontColor(Color.White).maxLines(2).id('devtools_picker_value')
          Text(this.coordinate).fontSize(13).fontColor('#E2E2E2').id('devtools_picker_xy')
          Text('重新取样').fontSize(14).fontColor('#A9D9FF').padding({ top: 4, bottom: 4 })
            .onClick((): void => { this.capture(); }).id('devtools_picker_refresh')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.devtools_close_white')).width(20).height(20).draggable(false)
        }.width(36).height(42).padding(0).backgroundColor(Color.Transparent)
        .onClick(this.onClose).accessibilityText('关闭取色器').id('devtools_picker_close')
      }.padding(6).width(Math.min(285, Math.max(0, this.bounds.right - this.bounds.left - 12)))
      .backgroundColor('#EA30353B').borderRadius(8)
      .position({ x: this.bounds.left + 6, y: this.y < (this.bounds.top + this.bounds.bottom) / 2 ?
        Math.max(this.bounds.top, this.bounds.bottom - LENS - 18) : this.bounds.top + 6 })
    }.width('100%').height('100%').clip(true).id('devtools_picker')
  }
}
