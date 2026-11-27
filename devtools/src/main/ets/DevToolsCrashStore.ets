import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hiAppEvent } from '@kit.PerformanceAnalysisKit';

interface CrashFrame {
  file?: string;
  pc?: string;
  symbol?: string;
  line?: number;
}

interface CrashSignal {
  signo: number;
  code?: number;
}

interface CrashException {
  name?: string;
  message?: string;
  stack?: string;
  frames?: CrashFrame[];
  signal?: CrashSignal;
}

interface CrashParameters {
  time: number;
  pid: number;
  bundle_name: string;
  bundle_version?: string;
  process_name?: string;
  crash_type: string;
  exception?: CrashException;
  external_log?: string[];
}

export interface DevToolsCrashRecord {
  id: string;
  time: number;
  pid: number;
  bundleName: string;
  version: string;
  processName: string;
  kind: string;
  reason: string;
  stack: string;
  reportPath: string;
}

interface CrashHistory {
  since: number;
  records: DevToolsCrashRecord[];
}

const MAX_RECORDS = 30;
const MAX_STACK = 12000;
const STATE_KEY = 'history';
const SIGNAL_NAMES: Map<number, string> = new Map<number, string>([
  [4, 'SIGILL'], [5, 'SIGTRAP'], [6, 'SIGABRT'], [7, 'SIGBUS'], [8, 'SIGFPE'], [11, 'SIGSEGV'], [31, 'SIGSYS']
]);

function shortText(value: string | undefined, limit: number): string {
  return typeof value === 'string' ? value.slice(0, limit) : '';
}

function crashReason(exception?: CrashException): string {
  const message = shortText(exception?.message, 1500);
  if (message) { return message; }
  const signal = exception?.signal;
  if (signal && Number.isInteger(signal.signo)) {
    const name = SIGNAL_NAMES.get(signal.signo);
    return 'Signal ' + signal.signo + (name ? ' (' + name + ')' : '') +
      (typeof signal.code === 'number' ? ', code ' + signal.code : '');
  }
  return shortText(exception?.name, 1500);
}

function crashRecord(event: hiAppEvent.AppEventInfo, bundle: string, since: number): DevToolsCrashRecord | undefined {
  if (event.name !== hiAppEvent.event.APP_CRASH || event.domain !== hiAppEvent.domain.OS || !event.params) {
    return undefined;
  }
  const p = event.params as CrashParameters;
  if (!Number.isFinite(p.time) || p.time < since || p.bundle_name !== bundle || !Number.isInteger(p.pid)) {
    return undefined;
  }
  const exception = p.exception;
  let stack = shortText(exception?.stack, MAX_STACK);
  const frames = exception?.frames;
  if (!stack && frames && Array.isArray(frames)) {
    stack = frames.slice(0, 100).filter((f: CrashFrame): boolean => !!f)
      .map((f: CrashFrame, i: number): string =>
        '#' + i + ' ' + shortText(f.pc, 30) + ' ' + shortText(f.file, 400) + ' ' + shortText(f.symbol, 300) +
        (f.line ? ':' + f.line : '')).join('\n').slice(0, MAX_STACK);
  }
  let reportPath = '';
  if (Array.isArray(p.external_log)) {
    const path = p.external_log.find((item: string): boolean =>
      typeof item === 'string' && /^\/data\/storage\/el[1-5]\/log\//.test(item) && !item.includes('..'));
    reportPath = shortText(path, 1024);
  }
  return { id: p.time + '-' + p.pid, time: p.time, pid: p.pid, bundleName: bundle,
    version: shortText(p.bundle_version, 100), processName: shortText(p.process_name, 240),
    kind: shortText(p.crash_type, 64), reason: crashReason(exception),
    stack: stack, reportPath: reportPath };
}

@ObservedV2
export class DevToolsCrashStore {
  @Trace enabled: boolean = false;
  @Trace records: DevToolsCrashRecord[] = [];
  @Trace error: string = '';
  private since: number = 0;
  private bundle: string = '';
  private store?: preferences.Preferences;
  private watcher?: hiAppEvent.Watcher;
  private users: number = 0;
  private generation: number = 0;

  // Each overlay in this process shares the watcher and the ordered history.
  attach(context: common.Context): void {
    if (++this.users > 1) { return; }
    this.bundle = context.applicationInfo.name;
    this.error = '';
    try {
      this.store = preferences.getPreferencesSync(context, { name: 'devtools_crash_history' });
      const raw = this.store.getSync(STATE_KEY, '');
      if (typeof raw === 'string' && raw.length > 0) {
        const data = JSON.parse(raw) as CrashHistory;
        this.since = Number.isFinite(data.since) ? data.since : 0;
        this.records = Array.isArray(data.records) ? data.records.filter((r: DevToolsCrashRecord): boolean =>
          !!r && typeof r.id === 'string' && Number.isFinite(r.time) && r.bundleName === this.bundle).slice(0, MAX_RECORDS) : [];
      }
      if (this.since > 0) { this.watch(); }
    } catch {
      this.error = '无法读取 Crash 设置或订阅系统事件';
    }
  }

  detach(): void {
    if (this.users === 0 || --this.users > 0) { return; }
    this.unwatch();
    this.store = undefined;
    this.records = [];
    this.since = 0;
    this.bundle = '';
  }

  setEnabled(enable: boolean): void {
    if (enable === this.enabled) { return; }
    const previous = this.since;
    if (enable) {
      if (!this.save(Date.now(), this.records)) { return; }
      if (!this.watch()) {
        this.save(previous, this.records);
        this.error = '无法订阅系统 Crash 事件，请重新开启';
      }
    } else if (this.save(0, this.records)) {
      this.unwatch();
    }
  }

  clear(): void {
    this.save(this.since > 0 ? Date.now() + 1 : 0, []);
  }

  private save(since: number, records: DevToolsCrashRecord[]): boolean {
    const data: CrashHistory = { since: since, records: records };
    try {
      if (!this.store) { throw new Error('Unavailable preferences'); }
      this.store.putSync(STATE_KEY, JSON.stringify(data));
      this.store.flushSync();
    } catch {
      const previous: CrashHistory = { since: this.since, records: this.records };
      try { this.store?.putSync(STATE_KEY, JSON.stringify(previous)); } catch { /* The store may have closed. */ }
      this.error = '未能保存 Crash 记录，请重试';
      return false;
    }
    this.since = since;
    this.records = records;
    this.error = '';
    return true;
  }

  private watch(): boolean {
    const revision = ++this.generation;
    const watcher: hiAppEvent.Watcher = {
      name: 'devtools_har_crash',
      appEventFilters: [{ domain: hiAppEvent.domain.OS, names: [hiAppEvent.event.APP_CRASH] }],
      onReceive: (domain: string, groups: hiAppEvent.AppEventGroup[]): void => {
        if (revision !== this.generation || this.since <= 0 || domain !== hiAppEvent.domain.OS) { return; }
        const next = this.records.slice();
        let changed = false;
        for (const group of groups) {
          for (const event of group.appEventInfos) {
            const record = crashRecord(event, this.bundle, this.since);
            if (record && !next.some((r: DevToolsCrashRecord): boolean => r.id === record.id)) {
              next.push(record);
              changed = true;
            }
          }
        }
        if (changed) {
          next.sort((a: DevToolsCrashRecord, b: DevToolsCrashRecord): number => b.time - a.time);
          this.save(this.since, next.slice(0, MAX_RECORDS));
        }
      }
    };
    try {
      hiAppEvent.addWatcher(watcher);
      this.watcher = watcher;
      this.enabled = true;
      return true;
    } catch {
      this.error = '无法订阅系统 Crash 事件，请重新开启';
      return false;
    }
  }

  private unwatch(): void {
    this.generation++;
    if (this.watcher) {
      try { hiAppEvent.removeWatcher(this.watcher); } catch { /* Late callbacks check the generation. */ }
    }
    this.watcher = undefined;
    this.enabled = false;
  }
}

export const devToolsCrashes: DevToolsCrashStore = new DevToolsCrashStore();
