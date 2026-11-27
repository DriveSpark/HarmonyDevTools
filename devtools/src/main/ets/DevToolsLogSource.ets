import { common } from '@kit.AbilityKit';
import { acquire, clear as clearCapturedLogs, readSince, release } from 'libdevtools_hilog.so';

export interface DevToolsLogEntry {
  readonly id: string;
  readonly time: number;
  readonly bundleName: string;
  readonly processName: string;
  readonly pid: number;
  readonly level: number;
  readonly tag: string;
  readonly message: string;
}

// Each mounted overlay or participating ability owns one source. The native callback is process-wide.
export class DevToolsLogSource {
  private capturing: boolean = false;
  private sourceBundle: string = '';
  private issue: string = '';
  private entries: DevToolsLogEntry[] = [];
  private sequence: number = 0;
  private first: number = 1;

  get bundleName(): string { return this.sourceBundle; }
  get active(): boolean { return this.capturing; }
  get error(): string { return this.issue; }

  start(context: common.Context): void {
    if (this.capturing) { return; }
    try {
      const app = context.getApplicationContext();
      this.sourceBundle = app.applicationInfo.name;
      acquire(app.cacheDir, this.sourceBundle, app.processName);
      this.capturing = true;
      this.issue = '';
    } catch {
      this.issue = '无法启用当前进程的 HiLog 采集';
    }
  }

  snapshot(): DevToolsLogEntry[] {
    if (this.capturing) {
      try {
        const update = readSince(this.sequence);
        if (this.entries.length > 0 && this.first < update.first) {
          this.entries = this.entries.filter((entry: DevToolsLogEntry): boolean => Number(entry.id) >= update.first);
        }
        if (update.entries.length > 0) {
          for (const entry of update.entries) {
            this.entries.push({
              id: entry.id, time: entry.time, bundleName: entry.bundleName, processName: entry.processName,
              pid: entry.pid, level: entry.level, tag: entry.tag, message: entry.message
            });
          }
          this.entries.sort((left: DevToolsLogEntry, right: DevToolsLogEntry): number =>
            left.time - right.time || Number(left.id) - Number(right.id));
        }
        this.sequence = update.latest;
        this.first = update.first;
        this.issue = update.writeFailed ? '部分 HiLog 记录采集失败' : '';
      } catch {
        this.issue = '读取 HiLog 记录失败';
      }
    }
    return this.entries.slice();
  }

  clear(): void {
    if (!this.capturing) { return; }
    try {
      clearCapturedLogs();
      this.entries = [];
      this.issue = '';
    } catch {
      this.issue = '清空 HiLog 记录失败';
    }
  }

  dispose(): void {
    if (this.capturing) { release(); }
    this.capturing = false;
    this.sourceBundle = '';
    this.issue = '';
    this.entries = [];
    this.sequence = 0;
    this.first = 1;
  }
}
