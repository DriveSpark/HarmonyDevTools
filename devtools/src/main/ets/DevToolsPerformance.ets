import { taskpool } from '@kit.ArkTS';
import { hidebug } from '@kit.PerformanceAnalysisKit';

// DoKit 3.7.11 schedules its next CPU or RAM read 500 ms after the previous read finishes.
const SAMPLE_INTERVAL_MS = 500;
const MAX_RECENT_SAMPLES = 120;

export type DevToolsMetric = 'cpu' | 'memory';

export interface DevToolsMetricSample {
  readonly timestamp: number;
  // CPU is a percentage and process PSS is in MiB. An unavailable reading has no numeric value.
  readonly value?: number;
}

@Concurrent
function collectCpuRatio(): number {
  return hidebug.getCpuUsage();
}

async function readCpuPercent(): Promise<number | undefined> {
  try {
    const ratio = await taskpool.execute(collectCpuRatio) as number;
    return Number.isFinite(ratio) && ratio >= 0 ? ratio * 100 : undefined;
  } catch {
    return undefined;
  }
}

async function readPssMiB(): Promise<number | undefined> {
  const memory = await hidebug.getAppNativeMemInfoAsync();
  const pssKiB = Number(memory.pss);
  return Number.isFinite(pssKiB) && pssKiB > 0 ? pssKiB / 1024 : undefined;
}

class DevToolsMetricRecorder {
  enabled: boolean = false;
  readonly samples: DevToolsMetricSample[] = [];

  private active: boolean = false;
  private generation: number = 0;
  private timerId?: number;
  private reading: boolean = false;
  private readonly read: () => Promise<number | undefined>;
  private readonly onSample: () => void;

  constructor(read: () => Promise<number | undefined>, onSample: () => void) {
    this.read = read;
    this.onSample = onSample;
  }

  setActive(active: boolean): void {
    if (this.active === active) { return; }
    this.active = active;
    this.generation++;
    if (this.timerId !== undefined) {
      clearTimeout(this.timerId);
      this.timerId = undefined;
    }
    this.schedule();
  }

  private schedule(): void {
    if (!this.active || this.reading || this.timerId !== undefined) { return; }
    const generation = this.generation;
    this.timerId = setTimeout((): void => {
      if (generation !== this.generation) { return; }
      this.timerId = undefined;
      this.collect(generation);
    }, SAMPLE_INTERVAL_MS);
  }

  private async collect(generation: number): Promise<void> {
    this.reading = true;
    let reading: number | undefined;
    try {
      reading = await this.read();
    } catch {
      // Preserve the timestamp of an unavailable SDK reading and retry on the next regular tick.
    }
    this.reading = false;
    // A stopped and restarted recorder waits for its old native read before scheduling another one.
    this.schedule();
    if (generation !== this.generation) { return; }
    if (this.samples.length === MAX_RECENT_SAMPLES) { this.samples.shift(); }
    this.samples.push({ timestamp: Date.now(), value: reading });
    this.onSample();
  }

  dispose(): void {
    this.setActive(false);
    this.enabled = false;
    this.samples.length = 0;
  }
}

// One instance belongs to one mounted host. Its detail pages can close and reopen independently.
export class DevToolsPerformance {
  private readonly listeners: Set<() => void> = new Set<() => void>();
  private readonly cpu: DevToolsMetricRecorder = new DevToolsMetricRecorder(readCpuPercent, (): void => this.notify());
  private readonly memory: DevToolsMetricRecorder = new DevToolsMetricRecorder(readPssMiB, (): void => this.notify());
  private foreground: boolean = false;
  private disposed: boolean = false;

  private recorder(metric: DevToolsMetric): DevToolsMetricRecorder {
    return metric === 'cpu' ? this.cpu : this.memory;
  }

  isEnabled(metric: DevToolsMetric): boolean {
    return this.recorder(metric).enabled;
  }

  setEnabled(metric: DevToolsMetric, enabled: boolean): void {
    const recorder = this.recorder(metric);
    if (this.disposed || recorder.enabled === enabled) { return; }
    recorder.enabled = enabled;
    recorder.setActive(enabled && this.foreground);
    this.notify();
  }

  setForeground(foreground: boolean): void {
    if (this.disposed || this.foreground === foreground) { return; }
    this.foreground = foreground;
    this.cpu.setActive(foreground && this.cpu.enabled);
    this.memory.setActive(foreground && this.memory.enabled);
  }

  latest(metric: DevToolsMetric): DevToolsMetricSample | undefined {
    const samples = this.recorder(metric).samples;
    return samples[samples.length - 1];
  }

  history(metric: DevToolsMetric): DevToolsMetricSample[] {
    return this.recorder(metric).samples.slice();
  }

  subscribe(listener: () => void): () => void {
    if (this.disposed) { return (): void => {}; }
    this.listeners.add(listener);
    return (): void => { this.listeners.delete(listener); };
  }

  private notify(): void {
    for (const listener of Array.from(this.listeners)) {
      if (this.listeners.has(listener)) { listener(); }
    }
  }

  dispose(): void {
    this.disposed = true;
    this.listeners.clear();
    this.cpu.dispose();
    this.memory.dispose();
  }
}
