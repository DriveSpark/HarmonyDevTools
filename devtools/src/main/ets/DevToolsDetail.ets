import { DevToolsAppInfo } from './DevToolsAppInfo';
import { DevToolsInfoPage } from './DevToolsCatalogSettings';
import { DevToolsBasicInfo } from './DevToolsInfo';
import { DevToolsMetricSample } from './DevToolsPerformance';

export type DevToolsDetailPage = DevToolsInfoPage | 'cpu' | 'memory' | 'cpuHistory' | 'memoryHistory';

const GRAPH_HEIGHT = 198;
const GRAPH_FLOOR = GRAPH_HEIGHT - 4;
const GRAPH_TOP = 17;
const GRAPH_VISIBLE_SAMPLES = 10;
const HISTORY_BACKGROUND = '#3F3F46';

function recordDate(timestamp: number): string {
  const date = new Date(timestamp);
  return `${date.getFullYear()}-${twoDigits(date.getMonth() + 1)}-${twoDigits(date.getDate())}`;
}

function recordTime(timestamp: number): string {
  const date = new Date(timestamp);
  return `${twoDigits(date.getHours())}:${twoDigits(date.getMinutes())}:${twoDigits(date.getSeconds())}`;
}

function twoDigits(part: number): string {
  return part.toString().padStart(2, '0');
}

function recordReading(reading: number | undefined, isCpu: boolean): string {
  if (reading === undefined) {
    return '—';
  }
  return `${reading.toFixed(1)}${isCpu ? '%' : ' MiB'}`;
}

@ComponentV2
struct DevToolsHistoryGraph {
  @Require @Param records: DevToolsMetricSample[];
  @Require @Param isCpu: boolean;
  @Event onRecordSelected: (sample: DevToolsMetricSample) => void = (): void => {};
  @Local private viewportWidth: number = 0;
  private readonly canvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private readonly scroller: Scroller = new Scroller();
  private canvasReady: boolean = false;
  private scrollOffset: number = 0;

  private sampleWidth(): number {
    return this.viewportWidth / GRAPH_VISIBLE_SAMPLES;
  }

  private contentWidth(): number {
    return Math.max(GRAPH_VISIBLE_SAMPLES, this.records.length) * this.sampleWidth();
  }

  @Monitor('records', 'isCpu', 'viewportWidth')
  redraw(): void {
    if (!this.canvasReady || this.viewportWidth <= 0) {
      return;
    }
    const ctx = this.canvas;
    ctx.clearRect(0, 0, this.viewportWidth, GRAPH_HEIGHT);
    if (this.records.length === 0) {
      return;
    }
    const peak = this.isCpu ? 100 : this.records.reduce((max: number, sample: DevToolsMetricSample): number =>
      Math.max(max, sample.value ?? 0), 1);
    const cell = this.sampleWidth();
    const first = Math.max(0, Math.floor(this.scrollOffset / cell) - 1);
    const end = Math.min(this.records.length, first + GRAPH_VISIBLE_SAMPLES + 3);
    const shade = ctx.createLinearGradient(0, GRAPH_TOP, 0, GRAPH_FLOOR);
    shade.addColorStop(0, 'rgba(0, 191, 255, 0.20)');
    shade.addColorStop(1, 'rgba(67, 67, 82, 0.20)');
    let previousY: number | undefined = undefined;
    for (let index = first; index < end; index++) {
      const reading = this.records[index].value;
      if (reading === undefined) {
        previousY = undefined;
        continue;
      }
      const x = (index + 0.5) * cell - this.scrollOffset;
      const y = GRAPH_FLOOR - (GRAPH_FLOOR - GRAPH_TOP) * Math.min(1, Math.max(0, reading / peak));
      if (previousY !== undefined) {
        ctx.beginPath();
        ctx.moveTo(x - cell, previousY);
        ctx.lineTo(x, y);
        ctx.lineTo(x, GRAPH_FLOOR);
        ctx.lineTo(x - cell, GRAPH_FLOOR);
        ctx.closePath();
        ctx.fillStyle = shade;
        ctx.fill();
        ctx.beginPath();
        ctx.moveTo(x - cell, previousY);
        ctx.lineTo(x, y);
        ctx.strokeStyle = 'rgba(0, 201, 244, 0.6)';
        ctx.lineWidth = 1;
        ctx.stroke();
      }
      ctx.beginPath();
      ctx.arc(x, y, 3, 0, Math.PI * 2);
      ctx.fillStyle = '#00C9F4';
      ctx.fill();
      previousY = y;
    }
    ctx.beginPath();
    ctx.moveTo(cell / 2 - this.scrollOffset, GRAPH_FLOOR);
    ctx.lineTo((this.records.length - 0.5) * cell - this.scrollOffset, GRAPH_FLOOR);
    ctx.lineWidth = 0.6;
    ctx.strokeStyle = '#999999';
    ctx.stroke();
  }

  private chooseAt(x: number): void {
    const width = this.sampleWidth();
    if (width <= 0) {
      return;
    }
    const index = Math.floor((this.scrollOffset + x) / width);
    if (index >= 0 && index < this.records.length) {
      this.onRecordSelected(this.records[index]);
    }
  }

  build() {
    Stack() {
      Canvas(this.canvas)
        .width('100%')
        .height('100%')
        .onReady((): void => {
          this.canvasReady = true;
          this.redraw();
        })
        .hitTestBehavior(HitTestMode.None)
      Scroll(this.scroller) {
        Row().width(this.contentWidth()).height(GRAPH_HEIGHT)
      }
      .width('100%')
      .height('100%')
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
      .onDidScroll((): void => {
        this.scrollOffset = this.scroller.currentOffset().xOffset;
        this.redraw();
      })
      .onClick((event: ClickEvent): void => this.chooseAt(event.x))
    }
    .width('100%')
    .height(GRAPH_HEIGHT)
    .onSizeChange((_before: SizeOptions, after: SizeOptions): void => {
      this.viewportWidth = Number(after.width);
    })
    .id('devtools_history_graph')
  }
}

@ComponentV2
struct DevToolsHistory {
  @Require @Param records: DevToolsMetricSample[];
  @Require @Param isCpu: boolean;
  @Local private selectedTimestamp?: number;

  @Computed
  get currentRecord(): DevToolsMetricSample | undefined {
    const selection = this.records.find((sample: DevToolsMetricSample): boolean => sample.timestamp === this.selectedTimestamp);
    return selection ?? this.records[Math.min(1, this.records.length - 1)];
  }

  private selectRecord(sample: DevToolsMetricSample): void {
    this.selectedTimestamp = sample.timestamp;
  }

  @Builder
  summary() {
    Row() {
      Row() {
        Column({ space: 3 }) {
          Text(this.currentRecord ? recordDate(this.currentRecord.timestamp) : '')
            .fontSize(8)
            .fontColor('#7FFFFFFF')
          Text(this.currentRecord ? recordTime(this.currentRecord.timestamp) : '')
            .fontSize(20)
            .fontColor('#7FFFFFFF')
            .id('devtools_history_time')
        }
        .alignItems(HorizontalAlign.Start)
      }
      .justifyContent(FlexAlign.End)
      .padding({ right: 25 })
      .layoutWeight(1)
      .height('100%')
      Divider().vertical(true).strokeWidth(0.5).color('#58585E').height('100%')
      Column({ space: 3 }) {
        Text(this.isCpu ? 'CPU' : '内存')
          .fontSize(8)
          .fontColor('#7FFFFFFF')
        Text(this.currentRecord ? recordReading(this.currentRecord.value, this.isCpu) : '')
          .fontSize(20)
          .fontColor(Color.White)
          .id('devtools_history_reading')
      }
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)
      .padding({ left: 25 })
      .layoutWeight(1)
      .height('100%')
    }
    .width('100%')
    .height(37)
    .margin({ top: 15.5, bottom: 15 })
  }

  build() {
    Column() {
      this.summary()
      DevToolsHistoryGraph({ records: this.records, isCpu: this.isCpu,
        onRecordSelected: (sample: DevToolsMetricSample): void => this.selectRecord(sample) })
      if (this.records.length > 0) {
        List({ space: 5 }) {
          ForEach(this.records, (sample: DevToolsMetricSample): void => {
            ListItem() {
              Row() {
                Text(recordDate(sample.timestamp))
                  .fontSize(14)
                  .fontColor('#7FFFFFFF')
                Text(recordTime(sample.timestamp))
                  .fontSize(14)
                  .fontColor(Color.White)
                  .margin({ left: 15 })
                Blank()
                if (sample.value !== undefined) {
                  Image($r('app.media.devtools_history_up')).width(5).height(6)
                }
                Text(recordReading(sample.value, this.isCpu))
                  .fontSize(14)
                  .fontColor('#79DE79')
              }
              .width('100%')
              .height(40)
              .padding({ left: 10, right: 50 })
              .backgroundColor('#333339')
              .borderRadius(2)
            }
            .onClick((): void => this.selectRecord(sample))
            .id(`devtools_history_sample_${sample.timestamp}`)
          }, (sample: DevToolsMetricSample): string => sample.timestamp.toString())
        }
        .width('100%')
        .padding({ left: 15, right: 15 })
        .margin({ top: 15 })
        .layoutWeight(1)
        .id('devtools_history_list')
      } else {
        Text('暂无检测记录')
          .fontSize(14)
          .fontColor('#B8B8C1')
          .margin({ top: 15 })
          .id('devtools_history_empty')
      }
    }
    .width('100%')
    .layoutWeight(1)
    .backgroundColor(HISTORY_BACKGROUND)
  }
}

@ComponentV2
export struct DevToolsDetail {
  @Require @Param page: DevToolsDetailPage;
  @Param info: DevToolsBasicInfo | undefined = undefined;
  @Param monitorEnabled: boolean = false;
  @Param records: DevToolsMetricSample[] = [];
  @Event onToggle: (checked: boolean) => void = (): void => {};
  @Event onHistory: () => void = (): void => {};
  @Event onBack: () => void = (): void => {};

  private title(): string {
    switch (this.page) {
      case 'appinfo': return 'App信息';
      case 'deviceinfo': return '设备信息';
      case 'screeninfo': return '屏幕信息';
      case 'cpu': return 'CPU';
      default: return '内存检测';
    }
  }

  @Builder
  homeTitle() {
    Row() {
      Button({ type: ButtonType.Normal }) {
        Image($r('app.media.devtools_close'))
          .width(28)
          .height(28)
          .objectFit(ImageFit.Contain)
      }
      .width(40)
      .height(44)
      .padding({ left: 12 })
      .backgroundColor(Color.Transparent)
      .accessibilityText('关闭')
      .onClick((): void => this.onBack())
      .id('devtools_detail_close')
      Text(this.title())
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor('#324456')
        .id('devtools_detail_title')
    }
    .width('100%')
    .height(89)
  }

  @Builder
  historyTitle() {
    Stack({ alignContent: Alignment.Start }) {
      Text('检测记录')
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#333333')
        .id('devtools_history_title')
      Row() {
        Image($r('app.media.devtools_back')).width(12).height(17).objectFit(ImageFit.Contain)
        Text('返回').fontSize(16).fontColor('#337CC4')
      }
      .height('100%')
      .padding({ left: 15, right: 8 })
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .onClick((): void => this.onBack())
      .id('devtools_history_back')
    }
    .width('100%')
    .height(44)
    .backgroundColor(Color.White)
  }

  @Builder
  monitorSettings() {
    Column() {
      Row() {
        Text(this.page === 'cpu' ? 'CPU检测开关' : '内存检测开关')
          .fontSize(16)
          .fontColor('#151515')
        Blank()
        Toggle({ type: ToggleType.Button, isOn: this.monitorEnabled }) {
          Image(this.monitorEnabled ? $r('app.media.devtools_switch_on') : $r('app.media.devtools_switch_off'))
            .width(44)
            .height(25)
            .objectFit(ImageFit.Contain)
        }
        .width(44)
        .height(25)
        .padding(0)
        .borderRadius(0)
        .backgroundColor(Color.Transparent)
        .selectedColor(Color.Transparent)
        .accessibilityText(this.page === 'cpu' ? 'CPU检测开关' : '内存检测开关')
        .accessibilityRole(AccessibilityRoleType.SWITCH)
        .onChange((checked: boolean): void => this.onToggle(checked))
        .id('devtools_monitor_switch')
      }
      .width('100%')
      .height(52)
      .border({ width: { bottom: '1px' }, color: '#E5E5E5' })
      Row() {
        Text('查看检测记录').fontSize(16).fontColor('#151515')
        Blank()
        Image($r('app.media.devtools_chevron'))
          .width(14)
          .height(14)
          .objectFit(ImageFit.Contain)
      }
      .width('100%')
      .height(52)
      .border({ width: { bottom: '1px' }, color: '#E5E5E5' })
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .onClick((): void => this.onHistory())
      .id('devtools_view_history')
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  build() {
    Column() {
      if (this.page === 'cpuHistory' || this.page === 'memoryHistory') {
        this.historyTitle()
        DevToolsHistory({ records: this.records, isCpu: this.page === 'cpuHistory' })
      } else {
        this.homeTitle()
        if (this.page === 'appinfo' || this.page === 'deviceinfo' || this.page === 'screeninfo') {
          DevToolsAppInfo({ page: this.page, info: this.info })
        } else {
          this.monitorSettings()
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.White)
    .id('devtools_detail')
  }
}
