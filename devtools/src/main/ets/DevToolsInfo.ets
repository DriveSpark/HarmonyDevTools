import { bundleManager } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { storageStatistics } from '@kit.CoreFileKit';
import { hidebug } from '@kit.PerformanceAnalysisKit';

export interface DevToolsBasicInfo {
  packageName?: string;
  appVersion?: string;
  brand?: string;
  manufacturer?: string;
  deviceType?: string;
  deviceModel?: string;
  systemVersion?: string;
  apiVersion?: string;
  cpuAbi?: string;
  totalMemory?: string;
}

export interface DevToolsDisplayInfo {
  resolution?: string;
  logicalSize?: string;
  orientation?: string;
  screenInches?: string;
  density?: string;
  densityDpi?: string;
  refreshRate?: string;
}

// DevEco's apiTransform appends the base API level as three decimal digits to the distribution version.
export function devToolsTargetApi(version: number): string | undefined {
  if (!Number.isSafeInteger(version) || version <= 0) {
    return undefined;
  }
  const level = version % 1000;
  return level > 0 ? level.toString() : undefined;
}

function deviceText(read: () => string): string | undefined {
  try {
    return read().trim() || undefined;
  } catch {
    return undefined;
  }
}

function readTotalMemory(): string | undefined {
  try {
    // HiDebug reports the system's MemTotal in KiB; storageStatistics reports bytes.
    const kib = Number(hidebug.getSystemMemInfo().totalMem);
    return Number.isFinite(kib) && kib > 0 ? `${(kib / (1024 * 1024)).toFixed(2)} GiB` : undefined;
  } catch {
    return undefined;
  }
}

export function readDevToolsDeviceInfo(): DevToolsBasicInfo {
  return {
    brand: deviceText((): string => deviceInfo.brand),
    manufacturer: deviceText((): string => deviceInfo.manufacture),
    deviceType: deviceText((): string => deviceInfo.deviceType),
    deviceModel: deviceText((): string => deviceInfo.productModel),
    systemVersion: deviceText((): string => deviceInfo.osFullName) ?? deviceText((): string => deviceInfo.displayVersion),
    apiVersion: deviceText((): string => deviceInfo.sdkApiVersion.toString()),
    cpuAbi: deviceText((): string => deviceInfo.abiList),
    totalMemory: readTotalMemory()
  };
}

export async function readDevToolsStorage(): Promise<string | undefined> {
  try {
    const sizes = await Promise.all([storageStatistics.getFreeSize(), storageStatistics.getTotalSize()]);
    const free = sizes[0];
    const total = sizes[1];
    if (Number.isFinite(free) && free >= 0 && positive(total)) {
      const gib = 1024 * 1024 * 1024;
      return `${(free / gib).toFixed(2)} GiB/${(total / gib).toFixed(2)} GiB`;
    }
  } catch {
    // Storage statistics may be unavailable on some devices.
  }
  return undefined;
}

async function readBasicInfo(): Promise<DevToolsBasicInfo> {
  const info = readDevToolsDeviceInfo();
  try {
    const bundle = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    info.packageName = bundle.name;
    info.appVersion = bundle.versionName ? `${bundle.versionName} (${bundle.versionCode})` : bundle.versionCode.toString();
  } catch {
    // The device fields are still available if the bundle service fails.
  }
  return info;
}

function positive(value: number): boolean {
  return Number.isFinite(value) && value > 0;
}

function screenOrientation(value?: display.Orientation): string | undefined {
  if (value === undefined) { return undefined; }
  switch (value) {
    case display.Orientation.PORTRAIT: return '竖屏';
    case display.Orientation.LANDSCAPE: return '横屏';
    case display.Orientation.PORTRAIT_INVERTED: return '反向竖屏';
    case display.Orientation.LANDSCAPE_INVERTED: return '反向横屏';
    default: return undefined;
  }
}

function describeDisplay(screen: display.Display): DevToolsDisplayInfo {
  const metrics: DevToolsDisplayInfo = { orientation: screenOrientation(screen.orientation) };
  if (positive(screen.width) && positive(screen.height)) {
    metrics.resolution = `${screen.width}x${screen.height}`;
    if (positive(screen.densityPixels)) {
      const width = Number((screen.width / screen.densityPixels).toFixed(1));
      const height = Number((screen.height / screen.densityPixels).toFixed(1));
      metrics.logicalSize = `${width} × ${height} vp`;
    }
    if (positive(screen.xDPI) && positive(screen.yDPI)) {
      const inches = Math.hypot(screen.width / screen.xDPI, screen.height / screen.yDPI);
      metrics.screenInches = `${inches.toFixed(1)} 英寸`;
    }
  }
  if (positive(screen.densityPixels)) {
    metrics.density = screen.densityPixels.toString();
  }
  if (positive(screen.densityDPI)) {
    metrics.densityDpi = `${screen.densityDPI} dpi`;
  }
  if (positive(screen.refreshRate)) {
    metrics.refreshRate = `${screen.refreshRate} Hz`;
  }
  return metrics;
}

export class DevToolsDisplaySession {
  private active: boolean = true;
  private readonly host: window.Window;
  private readonly publish: (metrics: DevToolsDisplayInfo | undefined) => void;
  private readonly onScreenChange = (id: number): void => this.refresh(id);
  private readonly onWindowMove = (): void => this.refresh();

  constructor(host: window.Window, publish: (metrics: DevToolsDisplayInfo | undefined) => void) {
    this.host = host;
    this.publish = publish;
    try {
      display.on('change', this.onScreenChange);
    } catch {
      // Window resizes and foreground transitions can still refresh the display.
    }
    try {
      this.host.on('displayIdChange', this.onWindowMove);
    } catch {
      // A closing window may already have stopped delivering move events.
    }
  }

  refresh(changedDisplay?: number): void {
    if (!this.active) {
      return;
    }
    let metrics: DevToolsDisplayInfo | undefined = undefined;
    try {
      const id = this.host.getWindowProperties().displayId;
      const screen = id === undefined ? display.getDefaultDisplaySync() : display.getDisplayByIdSync(id);
      if (changedDisplay !== undefined && changedDisplay !== (id ?? screen.id)) {
        return;
      }
      metrics = describeDisplay(screen);
    } catch {
      // Do not present coordinates of the previous screen after it has been disconnected.
    }
    this.publish(metrics);
  }

  dispose(): void {
    if (!this.active) {
      return;
    }
    this.active = false;
    try {
      display.off('change', this.onScreenChange);
    } catch {
      // The display service may already have released this subscription.
    }
    try {
      this.host.off('displayIdChange', this.onWindowMove);
    } catch {
      // A destroyed host window has already released its listeners.
    }
  }
}

// Each opening owns its reads. A late result from a dismissed panel cannot update a later opening.
export class DevToolsInfoSession {
  private active: boolean = true;

  async loadBasic(publish: (info: DevToolsBasicInfo) => void): Promise<void> {
    const info = await readBasicInfo();
    if (this.active) { publish(info); }
  }

  dispose(): void {
    this.active = false;
  }
}
