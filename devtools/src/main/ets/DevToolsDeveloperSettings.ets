import { common, Want, wantConstant } from '@kit.AbilityKit';
import { promptAction, UIContext } from '@kit.ArkUI';
import { deviceInfo, settings } from '@kit.BasicServicesKit';

const ENABLE_STEPS = '在「设置」中点本机名称或「关于本机」，连续点击「软件版本」7 次，按系统提示确认。若设备重启，请在重启后再试。';
const OPEN_IN_SYSTEM = '请在「系统」页面点开「开发者选项」';
const CHECK_STEPS = '请到「设置 → 系统 → 开发者选项」查看。如果没有这个入口，可按以下步骤开启。';

function readDeveloperMode(context: common.UIAbilityContext): boolean | undefined {
  try {
    const key = settings.general.DEVELOPMENT_SETTINGS_STATUS;
    if (key) {
      // An empty default distinguishes a missing setting from an explicit off value.
      const value = settings.getValueSync(context, key, '');
      if (value === 'true' || value === '1') { return true; }
      if (value === 'false' || value === '0') { return false; }
    }
  } catch {
    // Some OS versions do not expose this setting to applications.
  }
  return undefined;
}

// startAbility reports whether the launch was accepted. Settings controls its own navigation.
async function startSettingsPage(context: common.UIAbilityContext, uri: string, abilityName?: string): Promise<boolean> {
  try {
    const want: Want = { bundleName: 'com.huawei.hmos.settings', uri: uri };
    if (abilityName) { want.abilityName = abilityName; } else {
      want.action = 'ohos.want.action.viewData';
      want.flags = wantConstant.Flags.FLAG_START_WITHOUT_TIPS;
    }
    await context.startAbility(want);
    return true;
  } catch {
    return false;
  }
}

async function showSystemHint(ui: UIContext): Promise<void> {
  try {
    await ui.getPromptAction().openToast({
      message: OPEN_IN_SYSTEM, duration: 2000, showMode: promptAction.ToastShowMode.TOP_MOST
    });
    // A normal app's toast disappears when Settings becomes the foreground window.
    await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 1500); });
  } catch {
    // A host without a toast window can still open the System page.
  }
}

export class DevToolsDeveloperSettings {
  private sequence: number = 0;
  private pending?: number;

  cancel(): void {
    this.pending = undefined;
  }

  private async startDeveloperPage(context: common.UIAbilityContext, request: number): Promise<boolean> {
    const target = 'developer_options_settings';
    if (await startSettingsPage(context, target)) { return true; }
    // The explicit Want opens only the Settings home page on the API 26 emulator.
    if (this.pending !== request || deviceInfo.productModel === 'emulator') { return false; }
    return startSettingsPage(context, target, 'com.huawei.hmos.settings.MainAbility');
  }

  async open(ui: UIContext, showManualPath: () => void): Promise<void> {
    if (this.pending !== undefined) { return; }
    const request = ++this.sequence;
    this.pending = request;
    try {
      const context = ui.getHostContext() as common.UIAbilityContext | undefined;
      while (true) {
        const mode = context ? readDeveloperMode(context) : undefined;
        if (!context || mode === false) {
          await ui.getPromptAction().showDialog({
            title: mode === false ? '请先开启开发者选项' : '无法读取开发者选项状态',
            message: mode === false ? ENABLE_STEPS : CHECK_STEPS + '\n\n' + ENABLE_STEPS,
            buttons: [{ text: '知道了', color: '#337CC4' }]
          });
          return;
        }
        if (await this.startDeveloperPage(context, request) || this.pending !== request) { return; }
        if (mode === true) { break; }
        const choice = await ui.getPromptAction().showDialog({
          title: '未能打开开发者选项', message: '应用无法读取本机开关状态。' + CHECK_STEPS + '\n\n' + ENABLE_STEPS,
          buttons: [{ text: '取消', color: '#666666' }, { text: '前往系统', color: '#337CC4' },
            { text: '打开开发者选项', color: '#337CC4' }]
        });
        if (this.pending !== request) { return; }
        if (choice.index === 1) { break; }
        if (choice.index !== 2) { return; }
      }
      await showSystemHint(ui);
      if (this.pending !== request) { return; }
      const started = await startSettingsPage(context, 'system_and_updates');
      if (!started && this.pending === request) { showManualPath(); }
    } catch {
      // The host may close the guide or its window while the dialog is opening.
    } finally {
      if (this.pending === request) { this.pending = undefined; }
    }
  }
}
