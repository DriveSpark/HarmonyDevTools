import { FrameCallback } from '@kit.ArkUI';
import { DevToolsBounds } from './DevToolsLauncher';
import { saveDevToolsLogFile } from './DevToolsLogExport';
import {
  DEVTOOLS_LOG_DEBUG, DevToolsLogProcess, devToolsLogLevelCode, devToolsLogProcesses, filterDevToolsLogs,
  formatDevToolsLogTime
} from './DevToolsLogFilter';
import { DevToolsLogEntry, DevToolsLogSource } from './DevToolsLogSource';

const LOG_BLUE = '#337CC4';
const MINI_HEIGHT = 30;
const REFRESH_MS = 800;
const FULL_TEXT_LINES = 0x7FFFFFFF;

interface DevToolsLogLevel {
  number: number;
  label: string;
  background: string;
  foreground: string;
  text?: string;
}

const LOG_LEVELS: DevToolsLogLevel[] = [
  { number: 3, label: 'Debug', background: '#FFFF00', foreground: '#333333' },
  { number: 4, label: 'Info', background: '#00CC00', foreground: '#333333' },
  { number: 5, label: 'Warn', background: '#0066CC', foreground: '#CCCCCC', text: '#0099DD' },
  { number: 6, label: 'Error', background: '#CC0000', foreground: '#FFFFFF', text: '#FF0006' },
  { number: 7, label: 'Fatal', background: '#999900', foreground: '#FFFFFF', text: '#8F0005' }
];

function sameLogEntries(a: DevToolsLogEntry[], b: DevToolsLogEntry[]): boolean {
  return a.length === b.length && a.every((entry: DevToolsLogEntry, index: number): boolean => entry.id === b[index].id);
}

class DevToolsLogScrollFrame extends FrameCallback {
  private afterLayout: () => void;

  constructor(afterLayout: () => void) {
    super();
    this.afterLayout = afterLayout;
  }

  onIdle(_remaining: number): void {
    this.afterLayout();
  }
}

@ComponentV2
struct DevToolsLogRow {
  @Require @Param entry: DevToolsLogEntry;
  @Require @Param showDetails: boolean;

  @Computed private get levelStyle(): DevToolsLogLevel {
    return LOG_LEVELS[this.entry.level - DEVTOOLS_LOG_DEBUG] ?? LOG_LEVELS[0];
  }

  @Computed private get rowTextColor(): ResourceColor {
    return this.levelStyle.text ?? (this.showDetails ? Color.White : Color.Black);
  }

  build() {
    Column() {
      if (this.showDetails) {
        Row() {
          Text(`PID ${this.entry.pid}`).width(70).fontSize(12).fontColor(Color.White)
            .id(`devtools_log_entry_pid_${this.entry.id}`)
          Text(formatDevToolsLogTime(this.entry.time)).layoutWeight(1).fontSize(12).fontColor(Color.White)
            .id(`devtools_log_entry_time_${this.entry.id}`)
        }
        .width('100%')
        Text(`包名 ${this.entry.bundleName || '—'}`).width('100%').fontSize(12).fontColor(Color.White)
          .id(`devtools_log_entry_bundle_${this.entry.id}`)
      }
      Row() {
        Text(this.entry.tag).width(70).padding({ right: 2 }).fontSize(12).fontColor(this.rowTextColor)
          .maxLines(this.showDetails ? FULL_TEXT_LINES : 1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(devToolsLogLevelCode(this.entry.level)).width(15).fontSize(12).textAlign(TextAlign.Center)
          .backgroundColor(this.levelStyle.background).fontColor(this.levelStyle.foreground)
        Text(this.entry.message).layoutWeight(1).padding({ left: 2 }).fontSize(12).fontColor(this.rowTextColor)
          .maxLines(this.showDetails ? FULL_TEXT_LINES : 1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .id(`devtools_log_message_${this.entry.id}`)
      }
      .width('100%').alignItems(VerticalAlign.Top)
    }
    .width('100%').padding({ left: 3, right: 3, top: 2, bottom: 1 })
    .backgroundColor(this.showDetails ? Color.Black : Color.White)
  }
}

@ComponentV2
export struct DevToolsLogViewer {
  @Require @Param source: DevToolsLogSource;
  @Require @Param bounds: DevToolsBounds;
  @Require @Param expanded: boolean;
  @Param foreground: boolean = true;
  @Event onExpand: () => void = (): void => {};
  @Event onCollapse: () => void = (): void => {};
  @Event onClose: () => void = (): void => {};
  @Local private keyword: string = '';
  @Local private minimumLevel: number = DEVTOOLS_LOG_DEBUG;
  @Local private onlyCurrentApp: boolean = true;
  @Local private selectedPid?: number;
  @Local private processes: DevToolsLogProcess[] = [];
  @Local private displayRows: DevToolsLogEntry[] = [];
  @Local private expandedIds: Set<string> = new Set<string>();
  @Local private miniText: string = '日志';
  @Local private hasRecords: boolean = false;
  @Local private problem: string = '';
  @Local private exporting: boolean = false;
  private records: DevToolsLogEntry[] = [];
  private liveRows: DevToolsLogEntry[] = [];
  private currentBundle: string = '';
  private readonly listScroller: Scroller = new Scroller();
  private timer: number = -1;
  private mounted: boolean = false;
  private following: boolean = true;
  private userScrolling: boolean = false;
  private firstVisible: number = 0;
  private restorePending: boolean = false;
  private scrollRevision: number = 0;
  private exportRevision: number = 0;

  aboutToAppear(): void {
    this.mounted = true;
    this.syncRefresh();
  }

  aboutToDisappear(): void {
    this.mounted = false;
    clearInterval(this.timer);
    this.timer = -1;
    this.scrollRevision++;
    this.exportRevision++;
  }

  @Monitor('foreground')
  syncRefresh(): void {
    if (!this.mounted || !this.foreground) {
      clearInterval(this.timer);
      this.timer = -1;
      this.scrollRevision++;
      this.restorePending = false;
      return;
    }
    if (this.timer < 0) {
      this.refresh(false);
      this.timer = setInterval((): void => this.refresh(false), REFRESH_MS);
      if (this.following) {
        this.queueScroll(false);
      }
    }
  }

  @Monitor('source')
  sourceChanged(): void {
    this.exportRevision++;
    this.exporting = false;
    this.expandedIds = new Set<string>();
    this.selectedPid = undefined;
    this.records = [];
    this.liveRows = [];
    this.displayRows = [];
    this.processes = [];
    this.hasRecords = false;
    this.miniText = '日志';
    this.following = true;
    this.firstVisible = 0;
    this.refresh(true);
  }

  private refresh(force: boolean): void {
    if (!this.mounted || !this.foreground) {
      return;
    }
    try {
      const records = this.source.snapshot();
      this.problem = this.source.error || (this.source.active ? '' : '当前进程未启用日志采集');
      const bundle = this.source.bundleName;
      if (!force && bundle === this.currentBundle && sameLogEntries(this.records, records)) {
        return;
      }
      this.records = records;
      this.currentBundle = bundle;
      this.hasRecords = records.length > 0;
      this.updateProcesses();
      this.applyFilter(force);
    } catch {
      this.problem = '日志读取失败';
    }
  }

  private updateProcesses(): void {
    const next = devToolsLogProcesses(this.records, this.currentBundle, this.onlyCurrentApp);
    if (next.length !== this.processes.length || next.some((process: DevToolsLogProcess, index: number): boolean =>
      process.pid !== this.processes[index].pid || process.name !== this.processes[index].name)) {
      this.processes = next;
    }
  }

  private applyFilter(resetPosition: boolean): void {
    this.liveRows = filterDevToolsLogs(this.records, {
      bundleName: this.currentBundle, onlyCurrentApp: this.onlyCurrentApp,
      keyword: this.keyword, minimumLevel: this.minimumLevel, pid: this.selectedPid
    });
    const latest = this.liveRows[this.liveRows.length - 1];
    this.miniText = latest ? `${latest.tag}: ${latest.message.split('\n', 1)[0]}` :
      (this.hasRecords ? '暂无匹配日志' : '日志');
    if (resetPosition) {
      this.following = true;
      this.firstVisible = 0;
    }
    // Once the ring evicts the reading position, retain this bounded page until the reader returns to the end.
    if (!this.following && this.displayRows[this.firstVisible] &&
      this.displayRows[this.firstVisible].id !== this.liveRows[this.firstVisible]?.id) {
      return;
    }
    this.publishRows(resetPosition);
  }

  private publishRows(resetPosition: boolean): void {
    const changed = !sameLogEntries(this.displayRows, this.liveRows);
    if (changed) {
      this.displayRows = this.liveRows;
      if (this.expandedIds.size > 0) {
        const retained = new Set<string>();
        for (const entry of this.displayRows) {
          if (this.expandedIds.has(entry.id)) {
            retained.add(entry.id);
          }
        }
        if (retained.size !== this.expandedIds.size) {
          this.expandedIds = retained;
        }
      }
    }
    if (this.following && (changed || resetPosition)) {
      this.queueScroll(false);
    }
  }

  private queueScroll(restore: boolean): void {
    if (!this.foreground || !this.expanded || !this.mounted || this.displayRows.length === 0) {
      return;
    }
    const revision = ++this.scrollRevision;
    const anchor = this.firstVisible;
    this.restorePending = restore && !this.following;
    this.getUIContext().postFrameCallback(new DevToolsLogScrollFrame((): void => {
      if (revision !== this.scrollRevision || !this.mounted || !this.foreground || !this.expanded || !this.displayRows.length) {
        return;
      }
      if (this.following) {
        this.listScroller.scrollToIndex(this.displayRows.length - 1, false, ScrollAlign.END);
      } else if (restore) {
        this.listScroller.scrollToIndex(Math.min(anchor, this.displayRows.length - 1), false, ScrollAlign.START);
      }
      this.restorePending = false;
    }));
  }

  private userScrollStarted(offset: number, source: ScrollSource): void {
    if (offset !== 0 && source !== ScrollSource.SCROLLER && source !== ScrollSource.SCROLLER_ANIMATION) {
      this.userScrolling = true;
      this.following = false;
      this.restorePending = false;
      this.scrollRevision++;
    }
  }

  private userScrollStopped(): void {
    if (this.userScrolling) {
      this.userScrolling = false;
      if (this.expanded && this.listScroller.isAtEnd()) {
        this.following = true;
        this.publishRows(false);
      }
    }
  }

  private jump(bottom: boolean): void {
    if (!this.displayRows.length) {
      return;
    }
    this.following = bottom;
    this.userScrolling = false;
    this.restorePending = false;
    this.scrollRevision++;
    if (bottom) {
      this.publishRows(true);
    } else {
      this.firstVisible = 0;
      this.listScroller.scrollToIndex(0, false, ScrollAlign.START);
    }
  }

  private toggleDetails(id: string): void {
    const expanded = new Set<string>(this.expandedIds);
    if (expanded.has(id)) {
      expanded.delete(id);
    } else {
      expanded.add(id);
      this.following = false;
      this.scrollRevision++;
    }
    this.expandedIds = expanded;
  }

  private switchScope(checked: boolean): void {
    this.onlyCurrentApp = checked;
    this.updateProcesses();
    if (this.selectedPid !== undefined && !this.processes.some((p: DevToolsLogProcess): boolean =>
      p.pid === this.selectedPid)) {
      this.selectedPid = undefined;
    }
    this.applyFilter(true);
  }

  @Computed private get processOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: '全部进程' }];
    for (const process of this.processes) {
      options.push({ value: `${process.pid}  ${process.name}`.trim() });
    }
    if (this.selectedPid !== undefined && !this.processes.some((p: DevToolsLogProcess): boolean =>
      p.pid === this.selectedPid)) {
      options.push({ value: this.selectedPid.toString() });
    }
    return options;
  }

  private clearLogs(): void {
    try {
      this.source.clear();
      if (this.source.error) {
        this.notifyUser(this.source.error);
        return;
      }
      this.refresh(true);
    } catch {
      this.notifyUser('日志清空失败');
    }
  }

  private notifyUser(message: string): void {
    if (this.mounted) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: message });
      } catch { /* The host window can close before the picker returns. */ }
    }
  }

  private async exportLogs(): Promise<void> {
    if (this.exporting) {
      return;
    }
    const revision = ++this.exportRevision;
    this.exporting = true;
    try {
      const records = this.source.snapshot().slice();
      if (!records.length) {
        this.notifyUser('暂无日志信息可以导出');
        return;
      }
      const context = this.getUIContext().getHostContext();
      if (!context) {
        this.notifyUser('无法打开文件选择器');
        return;
      }
      const result = await saveDevToolsLogFile(context, records);
      if (revision === this.exportRevision && result !== 'canceled') {
        this.notifyUser(result === 'saved' ? `已导出 ${records.length} 条日志` : '日志导出失败');
      }
    } catch {
      if (revision === this.exportRevision) {
        this.notifyUser('日志导出失败');
      }
    } finally {
      if (revision === this.exportRevision) {
        this.exporting = false;
      }
    }
  }

  @Builder
  titleBar() {
    Stack() {
      Text('日志').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#333333').id('devtools_log_title')
      Row() {
        Button('最小化', { type: ButtonType.Normal }).height(44).padding({ left: 15, right: 8 })
          .fontSize(14).fontColor(LOG_BLUE).backgroundColor(Color.Transparent).id('devtools_log_collapse')
          .onClick((): void => { this.getUIContext().getFocusController().clearFocus(); this.onCollapse(); })
        Blank()
        Button({ type: ButtonType.Normal }) {
          Text('×').fontSize(26).fontColor('#333333').textAlign(TextAlign.Center)
        }
        .width(52).height(44).padding(0).backgroundColor(Color.Transparent).accessibilityText('关闭日志')
        .id('devtools_log_close').onClick((): void => { this.getUIContext().getFocusController().clearFocus(); this.onClose(); })
      }
      .width('100%')
    }
    .width('100%').height(this.compact ? 44 : 68).border({ width: { bottom: '1px' }, color: '#E5E5E5' })
  }

  @Computed private get compact(): boolean {
    return this.bounds.bottom - this.bounds.top < 400;
  }

  @Builder
  controls() {
    TextInput({ text: this.keyword, placeholder: '输入想要过滤的关键字' })
      .width('92%').height(this.compact ? 36 : 50).margin({ top: this.compact ? 4 : 15, bottom: this.compact ? 4 : 12 })
      .padding({ left: 15, right: 15 }).borderRadius(4).backgroundColor(Color.White)
      .border({ width: '1px', color: '#D8D8D8' }).fontSize(15).id('devtools_log_keyword')
      .onChange((text: string): void => { this.keyword = text; this.applyFilter(true); })
    Row() {
      ForEach(LOG_LEVELS, (level: DevToolsLogLevel): void => {
        Button(level.label, { type: ButtonType.Normal }).layoutWeight(1).height(this.compact ? 28 : 34)
          .padding(0).borderRadius(0).fontSize(14)
          .fontColor(this.minimumLevel === level.number ? Color.White : LOG_BLUE)
          .backgroundColor(this.minimumLevel === level.number ? LOG_BLUE : Color.White)
          .border({ width: '1px', color: LOG_BLUE }).accessibilityText(`${level.label} 及以上`)
          .id(`devtools_log_level_${devToolsLogLevelCode(level.number).toLowerCase()}`)
          .onClick((): void => { this.minimumLevel = level.number; this.applyFilter(true); })
      }, (level: DevToolsLogLevel): string => level.label)
    }
    .width('92%').constraintSize({ maxWidth: 350 }).borderRadius(4).clip(true)
    Row() {
      this.action('清空日志', 'clear', (): void => this.clearLogs())
      this.action('导出全部', 'export', (): void => { this.exportLogs(); })
      this.action('回到顶部', 'top', (): void => this.jump(false))
      this.action('滚至底部', 'bottom', (): void => this.jump(true))
    }
    .width('92%').constraintSize({ maxWidth: 300 }).margin({ top: 5 }).borderRadius(4).clip(true)
    Row({ space: 6 }) {
      Text('仅当前应用').fontSize(13).fontColor('#333333')
      Toggle({ type: ToggleType.Switch, isOn: this.onlyCurrentApp }).width(40).height(24).selectedColor(LOG_BLUE)
        .accessibilityText('仅当前应用').id('devtools_log_current_app').onChange((on: boolean): void => this.switchScope(on))
      Blank()
      Select(this.processOptions).value(this.selectedPid === undefined ? '全部进程' : `PID ${this.selectedPid}`)
        .controlSize(ControlSize.SMALL).font({ size: 13 }).accessibilityText('按进程筛选').id('devtools_log_pid')
        .onSelect((index: number, label: string): void => {
          this.selectedPid = index === 0 ? undefined : Number.parseInt(label, 10);
          this.applyFilter(true);
        })
    }
    .width('92%').constraintSize({ maxWidth: 350 }).height(this.compact ? 30 : 40)
  }

  @Builder
  action(title: string, suffix: string, perform: () => void) {
    Button(title, { type: ButtonType.Normal }).layoutWeight(1).height(this.compact ? 28 : 34).padding(0)
      .fontSize(14).fontColor(LOG_BLUE).backgroundColor(Color.White).border({ width: '1px', color: LOG_BLUE })
      .borderRadius(0).enabled(suffix !== 'export' || !this.exporting).id(`devtools_log_${suffix}`).onClick(perform)
  }

  @Builder
  logList() {
    List({ scroller: this.listScroller }) {
      Repeat<DevToolsLogEntry>(this.displayRows)
        .each((line: RepeatItem<DevToolsLogEntry>): void => {
          ListItem() {
            DevToolsLogRow({ entry: line.item, showDetails: this.expandedIds.has(line.item.id) })
          }
          .id(`devtools_log_row_${line.item.id}`).onClick((): void => this.toggleDetails(line.item.id))
        })
        .key((entry: DevToolsLogEntry): string => entry.id)
        .virtualScroll()
    }
    .width('100%').layoutWeight(1).maintainVisibleContentPosition(true).id('devtools_log_list')
    .onAppear((): void => this.queueScroll(true))
    .onWillScroll((offset: number, _state: ScrollState, source: ScrollSource): void => this.userScrollStarted(offset, source))
    .onScrollStop((): void => this.userScrollStopped())
    .onScrollIndex((first: number): void => {
      if (this.expanded && !this.restorePending) {
        this.firstVisible = Math.max(0, first);
      }
    })
  }

  build() {
    Column() {
      if (this.expanded) {
        this.titleBar()
        this.controls()
        if (this.problem || !this.displayRows.length) {
          Text(this.problem || (this.hasRecords ? '暂无匹配日志' : '暂无日志'))
            .width('100%').textAlign(TextAlign.Center).fontColor('#666666').fontSize(14).padding(8)
            .id('devtools_log_status')
        }
        this.logList()
      } else {
        Button({ type: ButtonType.Normal }) {
          Text(this.problem || this.miniText).width('100%').fontSize(14).fontColor(Color.White)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).id('devtools_log_latest')
        }
        .width('100%').height('100%').padding({ left: 4, right: 4 }).borderRadius(0).backgroundColor(LOG_BLUE)
        .accessibilityText(`展开日志，${this.miniText}`).id('devtools_log_mini').onClick((): void => this.onExpand())
      }
    }
    .width(Math.max(0, this.bounds.right - this.bounds.left))
    .height(Math.max(0, this.expanded ? this.bounds.bottom - this.bounds.top :
      Math.min(MINI_HEIGHT, this.bounds.bottom - this.bounds.top)))
    .position({ x: this.bounds.left, y: this.bounds.top })
    .backgroundColor(this.expanded ? Color.White : LOG_BLUE).clip(true).id('devtools_log_viewer')
  }
}
