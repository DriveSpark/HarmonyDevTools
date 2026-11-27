import { fileIo } from '@kit.CoreFileKit';
import { DevToolsCrashRecord, DevToolsCrashStore } from './DevToolsCrashStore';

@ComponentV2
struct DiagnosticHeader {
  @Require @Param title: string;
  @Event onBack: () => void = (): void => {};

  build() {
    Row() {
      Button({ type: ButtonType.Normal }) {
        Image($r('app.media.devtools_close')).width(28).height(28).draggable(false)
      }.width(45).height(48).backgroundColor(Color.Transparent).padding(0)
      .accessibilityText('返回').onClick(this.onBack).id('devtools_diagnostic_back')
      Text(this.title).fontSize(24).fontWeight(FontWeight.Bold).fontColor('#324456')
    }.width('100%').height(80).padding({ left: 6 })
  }
}

@ComponentV2
export struct DevToolsDeveloperOptions {
  @Event onBack: () => void = (): void => {};

  build() {
    Column() {
      DiagnosticHeader({ title: '开发者选项', onBack: this.onBack })
      Divider().color('#E5E5E5')
      Column({ space: 10 }) {
        Text('请手动进入系统设置').fontWeight(FontWeight.Bold).fontSize(18)
        Text('设置 → 系统 → 开发者选项').fontSize(16).copyOption(CopyOptions.LocalDevice)
        Text('首次开启').fontWeight(FontWeight.Bold).fontSize(18).margin({ top: 16 })
        Text('如果系统里还没有这个入口，打开设置中的设备名称或「关于本机」，连续点击「软件版本」7 次。按系统提示确认并输入锁屏密码，等待设备重启。')
          .fontSize(16).lineHeight(25)
      }.width('100%').padding(18).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').backgroundColor(Color.White).id('devtools_developer_page')
  }
}

@ComponentV2
export struct DevToolsCrashPage {
  @Require @Param store: DevToolsCrashStore;
  @Param selected: DevToolsCrashRecord | undefined = undefined;
  @Event onSelect: (record: DevToolsCrashRecord) => void = (): void => {};
  @Event onBack: () => void = (): void => {};
  @Local private report: string = '';
  private revision: number = 0;

  aboutToAppear(): void { this.loadReport(); }
  aboutToDisappear(): void { this.revision++; }

  @Monitor('selected')
  loadReport(): void {
    const version = ++this.revision;
    const selected = this.selected;
    this.report = '';
    if (!selected || selected.stack || !selected.reportPath) { return; }
    fileIo.readText(selected.reportPath, { length: 16384 }).then((body: string): void => {
      if (version === this.revision) { this.report = body; }
    }).catch((): void => {
      if (version === this.revision) { this.report = '系统报告文件当前不可读'; }
    });
  }

  @Builder
  private details(record: DevToolsCrashRecord) {
    Scroll() {
      Column({ space: 9 }) {
        Text(record.kind || 'Crash').fontSize(21).fontWeight(FontWeight.Bold)
        Text(new Date(record.time).toLocaleString()).fontSize(14)
        Text(record.bundleName + (record.version ? '  ·  ' + record.version : '')).fontSize(14)
        Text('PID ' + record.pid + (record.processName ? '  ·  ' + record.processName : '')).fontSize(14)
        Text(record.reason || '系统未提供异常原因').fontSize(16).copyOption(CopyOptions.LocalDevice)
          .id('devtools_crash_reason')
        Divider().color('#E5E5E5').margin({ top: 10, bottom: 8 })
        Text('调用栈').fontSize(17).fontWeight(FontWeight.Bold)
        Text(record.stack || this.report || '系统未提供调用栈').fontSize(14)
          .fontFamily('monospace').copyOption(CopyOptions.LocalDevice).id('devtools_crash_stack')
      }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
    }.layoutWeight(1).width('100%').align(Alignment.TopStart).id('devtools_crash_detail')
  }

  build() {
    Column() {
      DiagnosticHeader({ title: this.selected ? 'Crash 详情' : 'Crash', onBack: this.onBack })
      Divider().color('#E5E5E5')
      if (this.selected) {
        this.details(this.selected)
      } else {
        Row() {
          Text('Crash 监控').fontSize(17).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.store.enabled }).selectedColor('#337CC4')
            .onChange((value: boolean): void => this.store.setEnabled(value))
            .accessibilityText('Crash 监控').id('devtools_crash_switch')
        }.width('100%').height(58).padding({ left: 16, right: 16 })
        Text('开启后保存本应用的崩溃记录。崩溃后重新打开应用，可查看系统送达的报告。')
          .width('100%').fontSize(14).fontColor('#666666').padding({ left: 16, right: 16, bottom: 12 })
        Row() {
          Text('崩溃记录（' + this.store.records.length + '）').fontSize(16).fontWeight(FontWeight.Bold)
            .layoutWeight(1).id('devtools_crash_count')
          if (this.store.records.length > 0) {
            Text('清空').fontSize(15).fontColor('#337CC4').padding(8)
              .onClick((): void => this.store.clear()).id('devtools_crash_clear')
          }
        }.width('100%').height(45).backgroundColor('#F5F6F7').padding({ left: 16, right: 8 })
        if (this.store.error) {
          Text(this.store.error).width('100%').padding(12).fontSize(14).fontColor('#B23A3A')
        }
        if (this.store.records.length === 0) {
          Text('暂无崩溃记录').fontSize(15).fontColor('#787878').margin({ top: 40 }).id('devtools_crash_empty')
        } else {
          List() {
            ForEach(this.store.records, (record: DevToolsCrashRecord): void => {
              ListItem() {
                Column({ space: 5 }) {
                  Text(record.kind + '  ·  ' + new Date(record.time).toLocaleString()).fontWeight(FontWeight.Medium)
                  Text(record.reason || record.bundleName).fontSize(14).fontColor('#666666').maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }.padding(16).width('100%').alignItems(HorizontalAlign.Start)
              }.onClick((): void => this.onSelect(record)).id('devtools_crash_row_' + record.id)
            }, (record: DevToolsCrashRecord): string => record.id)
          }.layoutWeight(1).divider({ strokeWidth: 1, color: '#E5E5E5' })
        }
      }
    }.width('100%').height('100%').backgroundColor(Color.White).id('devtools_crash_page')
  }
}
