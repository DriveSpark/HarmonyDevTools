import { UIContext, window } from '@kit.ArkUI';
import { DevToolsAlignRuler } from './DevToolsAlignRuler';
import { DevToolsColorPicker } from './DevToolsColorPicker';
import { DevToolsCrashRecord, devToolsCrashes } from './DevToolsCrashStore';
import { DevToolsCrashPage, DevToolsDeveloperOptions } from './DevToolsDiagnosticPage';
import { DevToolsVisualId } from './DevToolsCatalogSettings';
import { DevToolsLogSource } from './DevToolsLogSource';
import { DevToolsLogViewer } from './DevToolsLogViewer';
import { DevToolsNodeInspector } from './DevToolsNodeInspector';
import { DevToolsBuiltinId, DevToolsCatalog, DevToolsCatalogState, DevToolsManager, DevToolsMore } from './DevToolsCatalog';
import { DevToolAction, DevToolsController } from './DevToolsController';
import { DevToolsDetail, DevToolsDetailPage } from './DevToolsDetail';
import { DevToolsBasicInfo, DevToolsInfoSession, readDevToolsDeviceInfo } from './DevToolsInfo';
import { DevToolsBounds, DevToolsLauncher } from './DevToolsLauncher';
import { DevToolsMetric, DevToolsMetricSample, DevToolsPerformance } from './DevToolsPerformance';
import { DevToolsPerformanceChart } from './DevToolsPerformanceChart';

type DevToolsPage = 'tools' | 'more' | 'manager' | 'developer' | 'crash' | DevToolsDetailPage;

interface DevToolsWindowBounds extends DevToolsBounds {
  statusBarHeight: number;
}

function visibleBounds(area: Area, host: window.Window | undefined, ui: UIContext): DevToolsWindowBounds {
  const bounds: DevToolsWindowBounds = {
    left: 0, top: 0, right: Number(area.width), bottom: Number(area.height), statusBarHeight: 0
  };
  if (!host) { return bounds; }
  try {
    const rect = host.getWindowProperties().windowRect;
    if (rect.width <= 0 || rect.height <= 0) { return bounds; }
    const x = Number(area.globalPosition.x ?? 0);
    const y = Number(area.globalPosition.y ?? 0);
    const types = [window.AvoidAreaType.TYPE_SYSTEM, window.AvoidAreaType.TYPE_CUTOUT,
      window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR, window.AvoidAreaType.TYPE_KEYBOARD];
    for (const type of types) {
      const avoid = host.getWindowAvoidArea(type);
      if (type === window.AvoidAreaType.TYPE_SYSTEM) { bounds.statusBarHeight = ui.px2vp(avoid.topRect.height); }
      bounds.left = Math.max(bounds.left, ui.px2vp(avoid.leftRect.width) - x);
      bounds.top = Math.max(bounds.top, ui.px2vp(avoid.topRect.height) - y);
      bounds.right = Math.min(bounds.right, ui.px2vp(rect.width - avoid.rightRect.width) - x);
      bounds.bottom = Math.min(bounds.bottom, ui.px2vp(rect.height - avoid.bottomRect.height) - y);
    }
  } catch { /* A host can be laid out before its window is available. */ }
  return bounds;
}

@ComponentV2
export struct DevToolsOverlay {
  @Require @Param controller: DevToolsController;
  @Param launcherVisible: boolean = true;
  @Param foreground: boolean = true;
  @Param captureHiLog: boolean = false;
  @Local private panelVisible: boolean = false;
  @Local private launcherHidden: boolean = false;
  @Local private page: DevToolsPage = 'tools';
  @Local private actions: DevToolAction[] = [];
  @Local private info?: DevToolsBasicInfo;
  @Local private cpuEnabled: boolean = false;
  @Local private memoryEnabled: boolean = false;
  @Local private visual?: DevToolsVisualId;
  @Local private logOpen: boolean = false;
  @Local private logExpanded: boolean = false;
  @Local private pickerCapturing: boolean = false;
  @Local private crashSelection?: DevToolsCrashRecord;
  @Local private cpuRecords: DevToolsMetricSample[] = [];
  @Local private memoryRecords: DevToolsMetricSample[] = [];
  @Local private bounds: DevToolsWindowBounds = { left: 0, top: 0, right: 0, bottom: 0, statusBarHeight: 0 };
  @Local private coverPadding: Padding = { left: 0, top: 0, right: 0, bottom: 0 };

  private readonly catalog: DevToolsCatalogState = new DevToolsCatalogState();
  private readonly logs: DevToolsLogSource = new DevToolsLogSource();
  private crashAttached: boolean = false;
  private pendingTool?: DevToolsVisualId | 'logs';
  private performance?: DevToolsPerformance;
  private infoSession?: DevToolsInfoSession;
  private attached: boolean = false;
  private owner?: DevToolsController;
  private unsubscribe?: () => void;
  private unbindBack?: () => void;
  private unbindOverlayBack?: () => void;
  private hostWindow?: window.Window;
  private hostArea?: Area;
  private coverArea?: Area;
  private readonly avoidChanged = (): void => this.updateBounds();

  aboutToAppear(): void {
    this.attached = true;
    this.catalog.load(this.getUIContext().getHostContext());
    this.connect();
  }

  aboutToDisappear(): void {
    this.attached = false;
    this.disconnect();
    try { this.hostWindow?.off('avoidAreaChange', this.avoidChanged); } catch { /* Window already closed. */ }
    this.hostWindow = undefined;
  }

  @Monitor('controller')
  connect(): void {
    const owner = this.controller;
    if (!this.attached || owner === this.owner) { return; }
    this.disconnect();
    this.owner = owner;
    const context = this.getUIContext().getHostContext();
    if (context) {
      devToolsCrashes.attach(context);
      this.crashAttached = true;
    }
    this.captureChanged();
    this.launcherHidden = false;
    this.performance = new DevToolsPerformance();
    this.performance.subscribe((): void => this.updateMeasurements());
    this.performance.setForeground(this.foreground);
    this.updateMeasurements();
    this.unbindBack = owner.bindPanelBack((): void => this.back());
    this.unbindOverlayBack = owner.bindOverlayBack((): boolean => {
      if (!this.foreground) { return false; }
      if (this.logOpen && this.logExpanded) {
        this.logExpanded = false;
        return true;
      }
      if (!this.visual) { return false; }
      this.visual = undefined;
      return true;
    });
    this.unsubscribe = owner.subscribe((): void => this.syncPanel(owner));
    this.syncPanel(owner);
  }

  private disconnect(): void {
    this.unsubscribe?.();
    this.unbindBack?.();
    this.unbindOverlayBack?.();
    this.unbindOverlayBack = undefined;
    this.logs.dispose();
    if (this.crashAttached) { devToolsCrashes.detach(); this.crashAttached = false; }
    this.unsubscribe = undefined;
    this.unbindBack = undefined;
    this.infoSession?.dispose();
    this.infoSession = undefined;
    this.performance?.dispose();
    this.performance = undefined;
    this.owner?.close();
    this.owner = undefined;
    this.panelVisible = false;
    this.visual = undefined;
    this.pendingTool = undefined;
    this.logOpen = false;
    this.logExpanded = false;
    this.crashSelection = undefined;
    this.pickerCapturing = false;
  }

  @Monitor('captureHiLog')
  captureChanged(): void {
    if (!this.owner || !this.captureHiLog) { this.logs.dispose(); return; }
    const context = this.getUIContext().getHostContext();
    if (context) { this.logs.start(context); }
  }

  @Monitor('foreground', 'launcherVisible')
  visibilityChanged(): void {
    this.performance?.setForeground(this.foreground);
    if (!this.foreground || !this.launcherVisible) { this.launcherHidden = false; }
    if (!this.launcherVisible || (!this.foreground && this.page === 'tools')) {
      this.owner?.close();
    }
  }

  private syncPanel(owner: DevToolsController): void {
    if (owner !== this.owner) { return; }
    const open = owner.isOpen;
    if (open && (!this.launcherVisible || (!this.foreground && !this.panelVisible))) { owner.close(); return; }
    if (open) {
      this.launcherHidden = false;
      this.pendingTool = undefined;
      this.actions = owner.getTools();
    }
    if (open === this.panelVisible) { return; }
    if (open) { this.page = 'tools'; this.crashSelection = undefined; }
    this.panelVisible = open;
    this.infoSession?.dispose();
    this.infoSession = undefined;
  }

  private showBuiltin(id: DevToolsBuiltinId): void {
    if (id === 'ruler' || id === 'logs' || id === 'colorpicker' || id === 'inspector' || id === 'borders') {
      this.pendingTool = id;
      this.owner?.close();
      return;
    }
    this.page = id;
    this.crashSelection = undefined;
    if (id === 'appinfo') {
      this.info = undefined;
      this.infoSession?.dispose();
      this.infoSession = new DevToolsInfoSession();
      this.infoSession.loadBasic((info: DevToolsBasicInfo): void => { this.info = info; });
    } else if (id === 'deviceinfo') {
      this.info = readDevToolsDeviceInfo();
    }
  }

  private back(): void {
    switch (this.page) {
      case 'tools': this.owner?.close(); break;
      case 'manager':
        if (!this.catalog.requestManagerBack()) { this.page = 'more'; }
        break;
      case 'cpuHistory': this.page = 'cpu'; break;
      case 'memoryHistory': this.page = 'memory'; break;
      case 'crash':
        if (this.crashSelection) { this.crashSelection = undefined; } else { this.page = 'tools'; }
        break;
      default:
        this.infoSession?.dispose();
        this.infoSession = undefined;
        this.page = 'tools';
    }
  }

  private updateMeasurements(): void {
    if (!this.performance) { return; }
    this.cpuEnabled = this.performance.isEnabled('cpu');
    this.memoryEnabled = this.performance.isEnabled('memory');
    this.cpuRecords = this.performance.history('cpu');
    this.memoryRecords = this.performance.history('memory');
  }

  private currentMetric(): DevToolsMetric {
    return this.page === 'memory' || this.page === 'memoryHistory' ? 'memory' : 'cpu';
  }

  private areaChanged(area: Area, cover: boolean): void {
    if (!this.attached) { return; }
    if (!this.hostWindow) {
      try {
        const name = this.getUIContext().getWindowName();
        if (name) {
          this.hostWindow = window.findWindow(name);
          this.hostWindow.on('avoidAreaChange', this.avoidChanged);
        }
      } catch { /* Use the component bounds until its window attaches. */ }
    }
    if (cover) { this.coverArea = area; } else { this.hostArea = area; }
    this.updateBounds();
  }

  private updateBounds(): void {
    if (this.hostArea) { this.bounds = visibleBounds(this.hostArea, this.hostWindow, this.getUIContext()); }
    if (this.coverArea) {
      const visible = visibleBounds(this.coverArea, this.hostWindow, this.getUIContext());
      this.coverPadding = { top: visible.top, left: visible.left,
        right: Math.max(0, Number(this.coverArea.width) - visible.right),
        bottom: Math.max(0, Number(this.coverArea.height) - visible.bottom) };
    }
  }

  private coverOptions(owner: DevToolsController): ContentCoverOptions {
    return {
      modalTransition: ModalTransition.NONE,
      backgroundColor: Color.White,
      onWillDismiss: (action: DismissContentCoverAction): void => {
        if (owner === this.owner && owner.isOpen) {
          if (this.page !== 'tools') { this.back(); return; }
          owner.close();
        }
        action.dismiss();
      },
      onDisappear: (): void => {
        if (owner !== this.owner) { return; }
        const tool = this.pendingTool;
        this.pendingTool = undefined;
        if (tool && !owner.isOpen && this.foreground) {
          if (tool === 'logs') { this.logOpen = true; this.logExpanded = true; }
          else { this.visual = tool; }
        }
        if (this.foreground && this.launcherVisible) { owner.panelDidDisappear(); }
        else if (!owner.isOpen) { owner.close(); }
      }
    };
  }

  @Builder
  liveCharts() {
    Column() {
      if (this.cpuEnabled) {
        DevToolsPerformanceChart({ metric: 'cpu', records: this.cpuRecords,
          onClose: (): void => { this.performance?.setEnabled('cpu', false); } })
      }
      if (this.memoryEnabled) {
        DevToolsPerformanceChart({ metric: 'memory', records: this.memoryRecords,
          onClose: (): void => { this.performance?.setEnabled('memory', false); } })
      }
    }.width('100%').hitTestBehavior(HitTestMode.None)
  }

  @Builder
  toolPage() {
    Column() {
      if (this.page === 'tools') {
        DevToolsCatalog({ actions: this.actions, settings: this.catalog,
          onOpenBuiltin: (id: DevToolsBuiltinId): void => this.showBuiltin(id),
          onHostAction: (id: string): void => { this.owner?.select(id); },
          onExit: (): void => { this.launcherHidden = true; this.owner?.close(); },
          onMore: (): void => { this.page = 'more'; }, onBack: (): void => this.back() })
      } else if (this.page === 'more') {
        DevToolsMore({ onManage: (): void => { this.page = 'manager'; }, onBack: (): void => this.back() })
      } else if (this.page === 'manager') {
        DevToolsManager({ settings: this.catalog, onBack: (): void => { this.page = 'more'; } })
      } else if (this.page === 'developer') {
        DevToolsDeveloperOptions({ onBack: (): void => this.back() })
      } else if (this.page === 'crash') {
        DevToolsCrashPage({ store: devToolsCrashes, selected: this.crashSelection,
          onSelect: (record: DevToolsCrashRecord): void => { this.crashSelection = record; },
          onBack: (): void => this.back() })
      } else {
        DevToolsDetail({ page: this.page as DevToolsDetailPage, info: this.info,
          monitorEnabled: this.currentMetric() === 'cpu' ? this.cpuEnabled : this.memoryEnabled,
          records: this.currentMetric() === 'cpu' ? this.cpuRecords : this.memoryRecords,
          onToggle: (enabled: boolean): void => { this.performance?.setEnabled(this.currentMetric(), enabled); },
          onHistory: (): void => { this.page = this.currentMetric() === 'cpu' ? 'cpuHistory' : 'memoryHistory'; },
          onBack: (): void => this.back() })
      }
    }
    .width('100%').height('100%')
  }

  @Builder
  panelContent() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.toolPage()
      if (this.foreground && (this.cpuEnabled || this.memoryEnabled) &&
        this.page !== 'tools' && this.page !== 'more' && this.page !== 'manager') {
        this.liveCharts()
      }
    }
    .width('100%').height('100%').padding(this.coverPadding)
    .backgroundColor(Color.White)
    .id('devtools_cover').onAreaChange((_before: Area, area: Area): void => this.areaChanged(area, true))
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.foreground && (this.cpuEnabled || this.memoryEnabled) && !this.panelVisible) {
        Column() {
          this.liveCharts()
        }.width('100%').position({ x: 0, y: this.bounds.top }).hitTestBehavior(HitTestMode.None)
      }
      if (this.foreground && this.launcherVisible && !this.launcherHidden && this.bounds.right - this.bounds.left >= 58 &&
        this.bounds.bottom - this.bounds.top >= 58) {
        DevToolsLauncher({ bounds: this.bounds, onOpen: (): void => { this.owner?.open(); } })
      }
      if (this.visual === 'ruler') {
        Stack() {
          DevToolsAlignRuler({ bounds: this.bounds, statusBarHeight: this.bounds.statusBarHeight,
            onClose: (): void => { this.visual = undefined; } })
        }.width('100%').height('100%').hitTestBehavior(HitTestMode.None)
        .visibility(this.foreground && !this.panelVisible ? Visibility.Visible : Visibility.Hidden)
      }
      if (this.foreground && !this.panelVisible && this.visual === 'colorpicker') {
        DevToolsColorPicker({ bounds: this.bounds,
          onCapturing: (hidden: boolean): void => { this.pickerCapturing = hidden; },
          onClose: (): void => { this.visual = undefined; } })
      }
      if (this.foreground && !this.panelVisible && (this.visual === 'inspector' || this.visual === 'borders')) {
        DevToolsNodeInspector({ bounds: this.bounds, mode: this.visual === 'inspector' ? 'inspector' : 'borders',
          onClose: (): void => { this.visual = undefined; } })
      }
      if (this.logOpen) {
        Stack({ alignContent: Alignment.TopStart }) {
          DevToolsLogViewer({ bounds: this.bounds, source: this.logs, expanded: this.logExpanded,
            foreground: this.foreground && !this.panelVisible,
            onExpand: (): void => { this.logExpanded = true; }, onCollapse: (): void => { this.logExpanded = false; },
            onClose: (): void => { this.logOpen = false; this.logExpanded = false; } })
        }.width('100%').height('100%').hitTestBehavior(HitTestMode.None)
        .visibility(this.foreground && !this.panelVisible ? Visibility.Visible : Visibility.Hidden)
      }
    }
    .width('100%').height('100%').hitTestBehavior(HitTestMode.None)
    .id('devtools_overlay').opacity(this.pickerCapturing ? 0 : 1)
    .onAreaChange((_before: Area, area: Area): void => this.areaChanged(area, false))
    .bindContentCover(this.panelVisible, this.panelContent, this.coverOptions(this.controller))
  }
}
