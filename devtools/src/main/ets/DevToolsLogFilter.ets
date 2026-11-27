import { DevToolsLogEntry } from './DevToolsLogSource';

export interface DevToolsLogFilterOptions {
  bundleName: string;
  onlyCurrentApp?: boolean;
  minimumLevel?: number;
  keyword?: string;
  pid?: number;
}

export interface DevToolsLogProcess {
  pid: number;
  name: string;
}

export const DEVTOOLS_LOG_DEBUG: number = 3;

class DevToolsLogQuery {
  private pid?: number;
  private tag: string = '';
  private text: string;
  private textPid?: number;

  constructor(keyword: string) {
    let remaining = keyword.toLowerCase();
    const pid = /\bpid:(\d+)\b/.exec(remaining);
    if (pid) {
      this.pid = Number(pid[1]);
      remaining = remaining.replace(pid[0], '');
    }
    const tag = /\btag:(?:"([^"]+)"|(\S+))/.exec(remaining);
    if (tag) {
      this.tag = tag[1] || tag[2];
      remaining = remaining.replace(tag[0], '');
    }
    this.text = remaining.trim();
    if (/^\d+$/.test(this.text)) {
      this.textPid = Number(this.text);
    }
  }

  matches(entry: DevToolsLogEntry): boolean {
    if (this.pid !== undefined && this.pid !== entry.pid) {
      return false;
    }
    if (!this.tag && !this.text) {
      return true;
    }
    const tag = entry.tag.toLowerCase();
    return tag.includes(this.tag) && (!this.text || this.textPid === entry.pid || tag.includes(this.text) ||
      entry.message.toLowerCase().includes(this.text));
  }
}

function inAppScope(entry: DevToolsLogEntry, bundleName: string, onlyCurrentApp: boolean): boolean {
  return !onlyCurrentApp || (bundleName.length > 0 && entry.bundleName === bundleName);
}

export function filterDevToolsLogs(entries: DevToolsLogEntry[], options: DevToolsLogFilterOptions): DevToolsLogEntry[] {
  const query = new DevToolsLogQuery(options.keyword ?? '');
  const onlyCurrentApp = options.onlyCurrentApp ?? true;
  const minimumLevel = options.minimumLevel ?? DEVTOOLS_LOG_DEBUG;
  return entries.filter((entry: DevToolsLogEntry): boolean =>
    inAppScope(entry, options.bundleName, onlyCurrentApp) && entry.level >= minimumLevel &&
    (options.pid === undefined || options.pid === entry.pid) && query.matches(entry));
}

export function devToolsLogProcesses(entries: DevToolsLogEntry[], bundleName: string,
  onlyCurrentApp: boolean): DevToolsLogProcess[] {
  const processes = new Map<number, DevToolsLogProcess>();
  for (const entry of entries) {
    if (inAppScope(entry, bundleName, onlyCurrentApp)) {
      processes.set(entry.pid, { pid: entry.pid, name: entry.processName });
    }
  }
  return Array.from(processes.values()).sort((a: DevToolsLogProcess, b: DevToolsLogProcess): number => a.pid - b.pid);
}

export function devToolsLogLevelCode(level: number): string {
  return 'DIWEF'.charAt(level - DEVTOOLS_LOG_DEBUG) || '?';
}

export function formatDevToolsLogTime(timestamp: number): string {
  const date = new Date(timestamp);
  const year = date.getFullYear();
  const month = (date.getMonth() + 1).toString().padStart(2, '0');
  const day = date.getDate().toString().padStart(2, '0');
  const hour = date.getHours().toString().padStart(2, '0');
  const minute = date.getMinutes().toString().padStart(2, '0');
  const second = date.getSeconds().toString().padStart(2, '0');
  const millis = date.getMilliseconds().toString().padStart(3, '0');
  return `${year}-${month}-${day} ${hour}:${minute}:${second}.${millis}`;
}
