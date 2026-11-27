export interface NativeLogEntry {
  id: string;
  time: number;
  bundleName: string;
  processName: string;
  pid: number;
  level: number;
  tag: string;
  message: string;
}

export interface NativeLogUpdate {
  first: number;
  latest: number;
  writeFailed: boolean;
  entries: NativeLogEntry[];
}

export function acquire(cacheDir: string, bundleName: string, processName: string): void;
export function readSince(sequence: number): NativeLogUpdate;
export function clear(): void;
export function release(): void;
