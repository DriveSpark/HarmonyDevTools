import { ApplicationStateChangeCallback, bundleManager, common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { DevToolsInfoPage } from './DevToolsCatalogSettings';
import { DevToolsBasicInfo, DevToolsDisplayInfo, DevToolsDisplaySession, devToolsTargetApi, readDevToolsStorage } from './DevToolsInfo';

interface DevToolsPermissionGroup {
  id: string;
  label: string;
  names: string[];
}

interface DevToolsPermissionRow {
  id: string;
  label: string;
  status: string;
}

const PERMISSION_GROUPS: DevToolsPermissionGroup[] = [
  { id: 'location', label: '地理位置权限', names: ['ohos.permission.APPROXIMATELY_LOCATION', 'ohos.permission.LOCATION'] },
  { id: 'camera', label: '拍照权限', names: ['ohos.permission.CAMERA'] },
  { id: 'microphone', label: '麦克风权限', names: ['ohos.permission.MICROPHONE'] },
  { id: 'contacts', label: '通讯录权限', names: ['ohos.permission.READ_CONTACTS'] }
];

interface DevToolsAppDetails {
  versionName?: string;
  versionCode?: string;
  targetApi?: string;
  permissions: DevToolsPermissionRow[];
}

function permissionStatus(names: string[], bundle?: bundleManager.BundleInfo): string {
  if (!bundle) {
    return '—';
  }
  let status = 'YES';
  for (const name of names) {
    const index = bundle.reqPermissionDetails.findIndex((item: bundleManager.ReqPermissionDetail): boolean =>
      item.name === name);
    const grant = bundle.permissionGrantStates[index];
    if (index < 0 || grant === bundleManager.PermissionGrantState.PERMISSION_DENIED) {
      return 'NO';
    }
    if (grant !== bundleManager.PermissionGrantState.PERMISSION_GRANTED) {
      status = '—';
    }
  }
  return status;
}

function permissionRows(bundle?: bundleManager.BundleInfo): DevToolsPermissionRow[] {
  return PERMISSION_GROUPS.map((group: DevToolsPermissionGroup): DevToolsPermissionRow => ({
    id: group.id, label: group.label, status: permissionStatus(group.names, bundle)
  }));
}

async function readAppDetails(): Promise<DevToolsAppDetails> {
  const details: DevToolsAppDetails = { permissions: permissionRows() };
  try {
    const bundle = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_REQUESTED_PERMISSION);
    details.versionName = bundle.versionName;
    details.versionCode = bundle.versionCode.toString();
    details.targetApi = devToolsTargetApi(bundle.targetVersion);
    details.permissions = permissionRows(bundle);
  } catch {
    // Other system services can still supply their own fields.
  }
  return details;
}

@ComponentV2
struct DevToolsAppInfoRow {
  @Require @Param label: string;
  @Param contentText: string | undefined = undefined;
  @Require @Param fieldId: string;
  @Param hideWhenEmpty: boolean = false;
  @Param isPermission: boolean = false;
  @Event onOpenSettings: () => void = (): void => {};

  build() {
    Row({ space: 10 }) {
      Text(this.label)
        .fontSize(16)
        .fontColor('#333333')
      Text(this.contentText ?? '—')
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .fontSize(16)
        .fontColor('#666666')
        .copyOption(CopyOptions.LocalDevice)
        .id(this.fieldId)
    }
    .width('100%')
    .visibility(this.hideWhenEmpty && !this.contentText ? Visibility.None : Visibility.Visible)
    .padding({ left: 10, right: 10, top: 14, bottom: 14 })
    .border({ width: { bottom: '1px' }, color: '#E5E5E5' })
    .onClick((): void => {
      if (this.isPermission) {
        this.onOpenSettings();
      }
    })
  }
}

@ComponentV2
export struct DevToolsAppInfo {
  @Require @Param page: DevToolsInfoPage;
  @Param info: DevToolsBasicInfo | undefined = undefined;
  @Local private details?: DevToolsAppDetails;
  @Local private storage?: string;
  @Local private screenInfo?: DevToolsDisplayInfo;
  private displaySession?: DevToolsDisplaySession;
  private displayWindowName?: string;
  private attached: boolean = false;
  private requestId: number = 0;
  private appContext?: common.ApplicationContext;
  private readonly appChange: ApplicationStateChangeCallback = {
    onApplicationForeground: (): void => { this.refresh(); },
    onApplicationBackground: (): void => {}
  };

  aboutToAppear(): void {
    this.attached = true;
    this.appContext = this.getUIContext().getHostContext()?.getApplicationContext();
    this.appContext?.on('applicationStateChange', this.appChange);
    this.refresh();
  }

  aboutToDisappear(): void {
    this.attached = false;
    this.requestId++;
    this.displaySession?.dispose();
    this.displaySession = undefined;
    this.displayWindowName = undefined;
    this.appContext?.off('applicationStateChange', this.appChange);
    this.appContext = undefined;
  }

  private async refresh(): Promise<void> {
    if (!this.attached) {
      return;
    }
    this.refreshScreen();
    if (this.page === 'screeninfo') {
      return;
    }
    const id = ++this.requestId;
    this.refreshStorage(id);
    if (this.page === 'appinfo') {
      const result = await readAppDetails();
      if (id === this.requestId) {
        this.details = result;
      }
    }
  }

  private async refreshStorage(id: number): Promise<void> {
    const storage = await readDevToolsStorage();
    if (id === this.requestId) {
      this.storage = storage;
    }
  }

  private refreshScreen(): void {
    if (!this.attached || this.page === 'deviceinfo') {
      return;
    }
    const name = this.getUIContext().getWindowName();
    if (this.displayWindowName !== name) {
      this.displaySession?.dispose();
      this.displaySession = undefined;
      this.displayWindowName = undefined;
      this.screenInfo = undefined;
      if (name) {
        try {
          const host = window.findWindow(name);
          this.displaySession = new DevToolsDisplaySession(host, (info: DevToolsDisplayInfo | undefined): void => {
            this.screenInfo = info;
          });
          this.displayWindowName = name;
        } catch {
          // Layout retries the lookup when the host window finishes attaching.
        }
      }
    }
    this.displaySession?.refresh();
  }

  private async openSettings(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    try {
      await context.startAbility({
        bundleName: 'com.huawei.hmos.settings',
        abilityName: 'com.huawei.hmos.settings.MainAbility',
        uri: 'application_info_entry',
        parameters: { pushParams: context.applicationInfo.name }
      });
    } catch {
      if (this.appContext) {
        try {
          this.getUIContext().getPromptAction().showToast({ message: '无法打开应用设置' });
        } catch {
          // A closed host window can no longer display a toast.
        }
      }
    }
  }

  private modelName(): string {
    const model = this.info?.deviceModel;
    const manufacturer = this.info?.manufacturer ?? this.info?.brand;
    if (manufacturer && model && !model.toLowerCase().startsWith(manufacturer.toLowerCase())) {
      return `${manufacturer} ${model}`;
    }
    return model || manufacturer || '—';
  }

  @Builder
  deviceRows() {
    if (this.page === 'deviceinfo') {
      DevToolsAppInfoRow({ label: '品牌', contentText: this.info?.brand, fieldId: 'devtools_brand' })
      DevToolsAppInfoRow({ label: '制造商', contentText: this.info?.manufacturer, fieldId: 'devtools_manufacturer' })
      DevToolsAppInfoRow({ label: '设备型号', contentText: this.info?.deviceModel, fieldId: 'devtools_model' })
      DevToolsAppInfoRow({ label: '设备类型', contentText: this.info?.deviceType, fieldId: 'devtools_device_type' })
    } else {
      DevToolsAppInfoRow({ label: '手机型号', contentText: this.modelName(), fieldId: 'devtools_model' })
    }
    DevToolsAppInfoRow({ label: '系统版本', contentText: this.info?.systemVersion ?? '—', fieldId: 'devtools_system' })
    DevToolsAppInfoRow({ label: 'API 版本', contentText: this.info?.apiVersion ?? '—', fieldId: 'devtools_api' })
    DevToolsAppInfoRow({ label: this.page === 'deviceinfo' ? '存储（可用/总量）' : '系统剩余空间',
      contentText: this.storage, fieldId: 'devtools_storage', hideWhenEmpty: this.page === 'appinfo' })
  }

  @Builder
  screenRows() {
    DevToolsAppInfoRow({ label: this.page === 'screeninfo' ? '分辨率（px）' : '分辨率',
      contentText: this.screenInfo?.resolution, fieldId: 'devtools_resolution', hideWhenEmpty: this.page === 'appinfo' })
    if (this.page === 'screeninfo') {
      DevToolsAppInfoRow({ label: '逻辑尺寸', contentText: this.screenInfo?.logicalSize, fieldId: 'devtools_logical_size' })
      DevToolsAppInfoRow({ label: '屏幕方向', contentText: this.screenInfo?.orientation, fieldId: 'devtools_orientation' })
    }
    DevToolsAppInfoRow({ label: '屏幕尺寸', contentText: this.screenInfo?.screenInches,
      fieldId: 'devtools_screen_size', hideWhenEmpty: this.page === 'appinfo' })
    DevToolsAppInfoRow({ label: this.page === 'screeninfo' ? '像素密度倍率' : 'DENSITY', contentText: this.screenInfo?.density,
      fieldId: 'devtools_density', hideWhenEmpty: this.page === 'appinfo' })
    DevToolsAppInfoRow({ label: '屏幕密度（DPI）', contentText: this.screenInfo?.densityDpi,
      fieldId: 'devtools_density_dpi', hideWhenEmpty: this.page === 'appinfo' })
    DevToolsAppInfoRow({ label: '屏幕刷新率', contentText: this.screenInfo?.refreshRate,
      fieldId: 'devtools_refresh_rate', hideWhenEmpty: this.page === 'appinfo' })
  }

  @Builder
  section(label: string) {
    Text(label)
      .width('100%')
      .height(56)
      .padding({ left: 5 })
      .fontSize(14)
      .fontColor('#999999')
      .border({ width: { bottom: '1px' }, color: '#E5E5E5' })
  }

  build() {
    Scroll() {
      Column() {
        if (this.page === 'appinfo') {
          this.section('App信息')
          DevToolsAppInfoRow({ label: '包名', contentText: this.info?.packageName ?? '—', fieldId: 'devtools_package' })
          DevToolsAppInfoRow({ label: '应用版本名', contentText: this.details?.versionName ?? '—', fieldId: 'devtools_version' })
          DevToolsAppInfoRow({ label: '应用版本号', contentText: this.details?.versionCode ?? '—', fieldId: 'devtools_version_code' })
          DevToolsAppInfoRow({ label: '目标系统版本号', contentText: this.details?.targetApi,
            fieldId: 'devtools_target_api', hideWhenEmpty: true })
          this.section('手机信息')
        }
        if (this.page !== 'screeninfo') {
          this.deviceRows()
        }
        if (this.page !== 'deviceinfo') {
          this.screenRows()
        }
        if (this.page !== 'screeninfo') {
          DevToolsAppInfoRow({ label: 'CPU 架构（ABI）', contentText: this.info?.cpuAbi,
            fieldId: 'devtools_abi', hideWhenEmpty: this.page === 'appinfo' })
          DevToolsAppInfoRow({ label: '整机物理内存', contentText: this.info?.totalMemory,
            fieldId: 'devtools_total_memory', hideWhenEmpty: this.page === 'appinfo' })
        }
        if (this.page === 'appinfo' && this.details && this.details.permissions.length > 0) {
          this.section('权限信息')
          ForEach(this.details.permissions, (row: DevToolsPermissionRow): void => {
            DevToolsAppInfoRow({ label: row.label, contentText: row.status, fieldId: `devtools_permission_${row.id}`,
              isPermission: true, onOpenSettings: (): void => { this.openSettings(); } })
          }, (row: DevToolsPermissionRow): string => `${row.id}_${row.status}`)
        }
      }
      .width('100%')
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.TopStart)
    .scrollBar(BarState.Off)
    .onSizeChange((): void => this.refreshScreen())
    .id(this.page === 'appinfo' ? 'devtools_app_info' : (this.page === 'deviceinfo' ? 'devtools_device_info' : 'devtools_screen_info'))
  }
}
