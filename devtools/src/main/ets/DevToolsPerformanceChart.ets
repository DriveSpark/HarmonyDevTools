import { DevToolsMetric, DevToolsMetricSample } from './DevToolsPerformance';

@ComponentV2
export struct DevToolsPerformanceChart {
  @Require @Param metric: DevToolsMetric;
  @Require @Param records: DevToolsMetricSample[];
  @Event onClose: () => void = (): void => {};
  private canvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ready: boolean = false;

  @Monitor('records')
  draw(): void {
    if (!this.ready) { return; }
    const ctx = this.canvas;
    const w = ctx.width;
    const h = ctx.height;
    ctx.clearRect(0, 0, w, h);
    if (w <= 25 || h <= 2 || !this.records.length) { return; }
    const now = this.records[this.records.length - 1].timestamp;
    const range = 12000;
    const visible = this.records.filter((s: DevToolsMetricSample): boolean => now - s.timestamp <= range);
    const max = visible.reduce((n: number, s: DevToolsMetricSample): number => Math.max(n, s.value ?? 0), 1);
    ctx.lineWidth = 0.5;
    ctx.strokeStyle = '#66999999';
    ctx.beginPath();
    ctx.moveTo(20, h - 2);
    ctx.lineTo(w, h - 2);
    ctx.stroke();
    ctx.fillStyle = '#00C9F4';
    ctx.strokeStyle = '#9900C9F4';
    ctx.lineWidth = 1.5;
    let lastX = 0;
    let lastY = 0;
    let lastTime = 0;
    for (const sample of visible) {
      if (sample.value === undefined) { lastTime = 0; continue; }
      const x = 20 + (w - 24) * (1 - (now - sample.timestamp) / range);
      const y = h - 2 - (h - 8) * sample.value / max;
      if (lastTime && sample.timestamp - lastTime < 2500) {
        ctx.beginPath();
        ctx.moveTo(lastX, lastY);
        ctx.lineTo(x, y);
        ctx.stroke();
      }
      ctx.beginPath();
      ctx.arc(x, y, 1.6, 0, 2 * Math.PI);
      ctx.fill();
      lastX = x;
      lastY = y;
      lastTime = sample.timestamp;
    }
  }

  private title(): string {
    const name = this.metric === 'cpu' ? 'CPU' : '内存';
    if (!this.records.length) { return name; }
    const value = this.records[this.records.length - 1].value;
    return name + '  ' + (value === undefined ? '暂不可用' : value.toFixed(1) + (this.metric === 'cpu' ? '%' : ' MiB'));
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Canvas(this.canvas)
        .width('100%').height(77).margin({ top: 15 })
        .onReady((): void => { this.ready = true; this.draw(); })
        .onAreaChange((): void => this.draw()).hitTestBehavior(HitTestMode.None)
      Text(this.title()).fontSize(11).fontColor(Color.White).margin({ left: 10, top: 5 })
        .id('devtools_chart_value_' + this.metric).hitTestBehavior(HitTestMode.None)
      Text('0').fontSize(10).fontColor(Color.White).margin({ left: 10, top: 83 }).hitTestBehavior(HitTestMode.None)
      Row() {
        Blank().hitTestBehavior(HitTestMode.None)
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.devtools_close_white')).width(14).height(14)
        }.width(36).height(36).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('关闭' + (this.metric === 'cpu' ? 'CPU' : '内存') + '检测')
          .id('devtools_chart_close_' + this.metric).onClick((): void => this.onClose())
      }.width('100%').hitTestBehavior(HitTestMode.None)
    }
    .width('100%').height(100).backgroundColor('#AA000000')
    .id('devtools_chart_' + this.metric).hitTestBehavior(HitTestMode.None)
  }
}
