import { HAR_VERSION } from '../../../BuildProfile';
import { DevToolAction } from './DevToolsController';
import { DevToolsDeveloperSettings } from './DevToolsDeveloperSettings';
import { DEVTOOLS_GROUPS, DevToolsBuiltinGroup, DevToolsBuiltinId, DevToolsBuiltinSetting, DevToolsCatalogState, isDevToolsBuiltinId } from './DevToolsCatalogSettings';

export { DevToolsBuiltinId, DevToolsCatalogState } from './DevToolsCatalogSettings';

const GROUP_DIVIDER = '#F5F6F7';
const LINE_COLOR = '#E5E5E5';
const TITLE_COLOR = '#333333';
const HEADING_COLOR = '#324456';
const BACK_COLOR = '#337CC4';

function groupTitle(group: DevToolsBuiltinGroup): string {
  switch (group) {
    case 'common': return '常用工具';
    case 'performance': return '性能监控';
    case 'visual': return '视觉工具';
  }
}

interface DevToolsCatalogEntry {
  id: string;
  title: string;
  artwork: Resource;
  builtinId?: DevToolsBuiltinId;
  checked: boolean;
}

interface DevToolsCatalogGroup {
  key: string;
  title: string;
  entries: DevToolsCatalogEntry[];
}

function builtinTool(setting: DevToolsBuiltinSetting): DevToolsCatalogEntry {
  let title: string;
  let artwork: Resource;
  switch (setting.id) {
    case 'appinfo':
      title = 'App信息';
      artwork = $r('app.media.devtools_app_info');
      break;
    case 'deviceinfo':
      title = '设备信息';
      artwork = $r('app.media.devtools_device_info');
      break;
    case 'screeninfo':
      title = '屏幕信息';
      artwork = $r('app.media.devtools_screen_info');
      break;
    case 'cpu':
      title = 'CPU';
      artwork = $r('app.media.devtools_cpu');
      break;
    case 'memory':
      title = '内存';
      artwork = $r('app.media.devtools_memory');
      break;
    case 'ruler':
      title = '对齐标尺';
      artwork = $r('app.media.devtools_align_ruler');
      break;
    case 'developer':
      title = '开发者选项';
      artwork = $r('app.media.devtools_developer');
      break;
    case 'logs':
      title = '日志';
      artwork = $r('app.media.devtools_log');
      break;
    case 'crash':
      title = 'Crash';
      artwork = $r('app.media.devtools_crash');
      break;
    case 'colorpicker':
      title = '取色器';
      artwork = $r('app.media.devtools_color_picker');
      break;
    case 'inspector':
      title = '控件检查';
      artwork = $r('app.media.devtools_view_check');
      break;
    case 'borders':
      title = '布局边框';
      artwork = $r('app.media.devtools_layout_border');
      break;
  }
  return { id: setting.id, builtinId: setting.id, title: title, artwork: artwork, checked: setting.checked };
}

function builtinGroups(settings: DevToolsCatalogState): DevToolsCatalogGroup[] {
  const result: DevToolsCatalogGroup[] = [];
  for (const group of DEVTOOLS_GROUPS) {
    const entries = settings.tools(group).map(builtinTool);
    if (entries.length > 0) {
      result.push({ key: group, title: groupTitle(group), entries: entries });
    }
  }
  return result;
}

function hostGroups(actions: DevToolAction[]): DevToolsCatalogGroup[] {
  const groups = new Map<string, DevToolsCatalogGroup>();
  for (const action of actions) {
    const title = action.group || '业务专区';
    let group = groups.get(title);
    if (!group) {
      group = { key: `host:${title}`, title: title, entries: [] };
      groups.set(title, group);
    }
    group.entries.push({ id: action.id, title: action.title,
      artwork: action.icon ?? $r('app.media.devtools_custom'), checked: true });
  }
  return Array.from(groups.values());
}

function catalogToolId(tool: DevToolsCatalogEntry): string {
  if (!tool.builtinId && isDevToolsBuiltinId(tool.id)) {
    return `devtools_host_tool_${tool.id}`;
  }
  return `devtools_tool_${tool.id}`;
}

@ComponentV2
struct DevToolsCatalogHeading {
  @Require @Param groupName: string;

  build() {
    Column() {
      Row().width('100%').height(15).backgroundColor(GROUP_DIVIDER)
      Text(this.groupName)
        .maxLines(1)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(HEADING_COLOR)
        .margin({ left: 16, top: 10, bottom: 10 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

@ComponentV2
struct DevToolsCatalogIcon {
  @Require @Param tool: DevToolsCatalogEntry;
  @Param inCatalog: boolean = false;

  build() {
    Column() {
      Image(this.tool.artwork)
        .width(34)
        .height(34)
        .objectFit(ImageFit.Contain)
        .draggable(false)
      Text(this.tool.title)
        .fontSize(12)
        .fontColor('#151515')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 6 })
    }
    .width(this.inCatalog ? 75 : '100%')
    .constraintSize({ maxWidth: '100%' })
    .alignItems(HorizontalAlign.Center)
  }
}

@ComponentV2
struct DevToolsCatalogBar {
  @Param manager: boolean = false;
  @Param editing: boolean = false;
  @Event onBack: () => void = (): void => {};
  @Event onRight: () => void = (): void => {};
  @Event onReset: () => void = (): void => {};

  build() {
    Stack() {
      Text(this.manager ? '管理我的功能' : 'DevTools')
        .fontWeight(FontWeight.Bold)
        .fontSize(18)
        .fontColor(TITLE_COLOR)
      Row() {
        Row() {
          Image($r('app.media.devtools_back')).width(12).height(17).draggable(false)
          Text('返回').fontSize(16).fontColor(BACK_COLOR)
        }
        .height('100%')
        .onClick((): void => this.onBack())
        .accessibilityGroup(true)
        .accessibilityText('返回')
        .id(this.manager ? 'devtools_manager_back' : 'devtools_close')
        Blank()
        if (this.manager && this.editing) {
          Text('还原')
            .height('100%')
            .fontSize(16)
            .fontColor(BACK_COLOR)
            .margin({ right: 10 })
            .onClick((): void => this.onReset())
            .id('devtools_manager_reset')
        }
        Text(this.manager ? (this.editing ? '完成' : '编辑') : '更多')
          .height('100%')
          .fontSize(this.manager ? 16 : 14)
          .fontColor(this.manager ? (this.editing ? BACK_COLOR : TITLE_COLOR) : '#666666')
          .onClick((): void => this.onRight())
          .id(this.manager ? 'devtools_manager_edit' : 'devtools_more')
      }
      .width('100%')
      .height('100%')
      .padding({ left: this.manager ? 16 : 15, right: this.manager ? 16 : 10 })
    }
    .width('100%')
    .height(this.manager ? 46 : 46.5)
  }
}

@ComponentV2
export struct DevToolsCatalog {
  @Require @Param actions: DevToolAction[];
  @Require @Param settings: DevToolsCatalogState;
  @Event onOpenBuiltin: (id: DevToolsBuiltinId) => void = (): void => {};
  @Event onHostAction: (id: string) => void = (): void => {};
  @Event onMore: () => void = (): void => {};
  @Event onBack: () => void = (): void => {};
  @Event onExit: () => void = (): void => {};
  private readonly developerSettings: DevToolsDeveloperSettings = new DevToolsDeveloperSettings();

  aboutToDisappear(): void {
    this.developerSettings.cancel();
  }

  @Computed
  get groups(): DevToolsCatalogGroup[] {
    return hostGroups(this.actions).concat(builtinGroups(this.settings));
  }

  private selectTool(tool: DevToolsCatalogEntry): void {
    if (tool.builtinId === 'developer') {
      this.developerSettings.open(this.getUIContext(), (): void => this.onOpenBuiltin('developer'));
    } else if (tool.builtinId) {
      this.onOpenBuiltin(tool.builtinId);
    } else {
      this.onHostAction(tool.id);
    }
  }

  build() {
    Column() {
      DevToolsCatalogBar({ onBack: this.onBack, onRight: this.onMore })
      Row().width('100%').height(5).backgroundColor(GROUP_DIVIDER)
      Scroll() {
        Column() {
          Repeat<DevToolsCatalogGroup>(this.groups)
            .each((section: RepeatItem<DevToolsCatalogGroup>): void => {
              Column() {
                DevToolsCatalogHeading({ groupName: section.item.title })
                Flex({ wrap: FlexWrap.Wrap }) {
                  Repeat<DevToolsCatalogEntry>(section.item.entries)
                    .each((entry: RepeatItem<DevToolsCatalogEntry>): void => {
                      Row() {
                        DevToolsCatalogIcon({ tool: entry.item, inCatalog: true })
                      }
                      .width('25%')
                      .padding({ left: 10, bottom: 16 })
                      .onClick((): void => this.selectTool(entry.item))
                      .accessibilityGroup(true)
                      .accessibilityText(entry.item.title)
                      .id(catalogToolId(entry.item))
                    })
                    .key((tool: DevToolsCatalogEntry): string => tool.id)
                }
                .width('100%')
              }
              .width('100%')
            })
            .key((group: DevToolsCatalogGroup): string => group.key)
          Column() {
            Text('退出 DevTools')
              .width('100%')
              .height(50)
              .textAlign(TextAlign.Center)
              .fontSize(14)
              .fontColor('#CC3A4B')
              .backgroundColor(Color.White)
              .borderRadius(4)
              .shadow({ radius: 2, color: '#33000000', offsetY: 1 })
              .margin({ top: 15, bottom: 15 })
              .onClick((): void => this.onExit())
              .id('devtools_exit')
            Text(`当前版本：V${HAR_VERSION}`)
              .width('100%')
              .textAlign(TextAlign.Center)
              .fontSize(12)
              .fontColor('#999999')
              .id('devtools_library_version')
          }
          .width('100%')
          .padding({ left: 15, right: 15 })
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
    }
    .width('100%')
    .height('100%')
    .id('devtools_panel')
  }
}

@ComponentV2
export struct DevToolsMore {
  @Event onManage: () => void = (): void => {};
  @Event onBack: () => void = (): void => {};

  build() {
    Column() {
      Row() {
        Image($r('app.media.devtools_close'))
          .width(28)
          .height(28)
          .margin({ left: 12 })
          .draggable(false)
          .accessibilityText('返回')
          .onClick((): void => this.onBack())
          .id('devtools_more_back')
        Text('更多').fontSize(24).fontColor(HEADING_COLOR).fontWeight(FontWeight.Bold)
      }
      .width('100%')
      .height(89)
      Text('本地功能')
        .fontWeight(FontWeight.Bold)
        .fontSize(18)
        .fontColor(TITLE_COLOR)
        .margin({ top: 10 })
      Column() {
        Row() {
          Column() {
            Text('功能管理').fontSize(16).fontColor(TITLE_COLOR)
            Text('介绍:可以针对DevTools的内置工具列表进行自定义排序')
              .fontSize(14)
              .fontColor('#999999')
              .margin({ top: 5 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Image($r('app.media.devtools_chevron'))
            .width(14)
            .height(14)
            .draggable(false)
            .margin({ left: 8 })
        }
        .width('100%')
        Divider().strokeWidth('1px').color(LINE_COLOR).margin({ top: 5 })
      }
      .width('100%')
      .padding({ top: 5, bottom: 5 })
      .onClick((): void => this.onManage())
      .accessibilityGroup(true)
      .accessibilityText('功能管理')
      .id('devtools_open_manager')
    }
    .width('100%')
    .height('100%')
    .padding({ left: 15, right: 15 })
    .alignItems(HorizontalAlign.Start)
    .id('devtools_more_page')
  }
}

@ComponentV2
struct DevToolsManagerDialogView {
  @Require @Param settings: DevToolsCatalogState;
  @Event onBack: () => void = (): void => {};

  private resolve(positive: boolean): void {
    if (this.settings.resolveConfirmation(positive)) { this.onBack(); }
  }

  build() {
    Stack() {
      Row()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .hitTestBehavior(HitTestMode.Block)
        .onClick((): void => this.settings.dismissNotice())
      if (this.settings.dialog === 'save' || this.settings.dialog === 'reset') {
        Column() {
          Text('提示').fontSize(21).fontColor(TITLE_COLOR).fontWeight(FontWeight.Bold)
          Text(this.settings.dialog === 'save' ? '是否保存已编辑的内容' : '是否还原到初始状态')
            .fontSize(14)
            .fontColor(TITLE_COLOR)
            .margin({ top: 5, bottom: 15 })
          Divider().strokeWidth('1px').color(LINE_COLOR)
          Row() {
            Text('取消')
              .layoutWeight(1)
              .height('100%')
              .textAlign(TextAlign.Center)
              .fontSize(14)
              .fontColor('#55A8FD')
              .onClick((): void => this.resolve(false))
              .id('devtools_manager_cancel')
            Divider().vertical(true).strokeWidth('1px').color(LINE_COLOR)
            Text('确定')
              .layoutWeight(1)
              .height('100%')
              .textAlign(TextAlign.Center)
              .fontSize(14)
              .fontColor('#55A8FD')
              .onClick((): void => this.resolve(true))
              .id('devtools_manager_confirm')
          }
          .width('100%')
          .height(48)
        }
        .width(280)
        .constraintSize({ maxWidth: '95%' })
        .padding({ top: 30 })
        .backgroundColor(Color.White)
        .borderRadius(18)
      } else {
        Column() {
          if (this.settings.dialog !== 'failed') {
            Image($r('app.media.devtools_done')).width(45).height(45).draggable(false)
          }
          Text(this.settings.dialog === 'restored' ? '功能还原成功' :
            (this.settings.dialog === 'failed' ? '保存失败' : '保存成功'))
            .fontSize(13)
            .fontColor('#666666')
            .margin({ top: this.settings.dialog === 'failed' ? 0 : 12 })
        }
        .width(135)
        .height(124)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Color.White)
        .borderRadius(5)
      }
    }
    .width('100%')
    .height('100%')
    .id('devtools_manager_dialog')
  }
}

@ComponentV2
export struct DevToolsManager {
  @Require @Param settings: DevToolsCatalogState;
  @Event onBack: () => void = (): void => {};
  @Local private draggedId?: DevToolsBuiltinId;
  @Local private dragOffsetX: number = 0;
  @Local private dragOffsetY: number = 0;
  private dragStartX: number = 0;
  private dragStartY: number = 0;
  private suppressTap: boolean = false;

  aboutToDisappear(): void { this.settings.leaveManager(); }

  private toggleEditing(): void {
    if (this.settings.editing) {
      this.settings.finishEditing();
    } else {
      this.settings.beginEditing();
    }
  }

  private beginDrag(id: DevToolsBuiltinId | undefined, event: GestureEvent): void {
    const touch = event.fingerList[0];
    if (!this.settings.editing || !id || !touch) { return; }
    this.suppressTap = true;
    this.dragStartX = touch.globalX;
    this.dragStartY = touch.globalY;
    this.dragOffsetX = 0;
    this.dragOffsetY = 0;
    this.draggedId = id;
  }

  private updateDrag(event: GestureEvent): void {
    if (!this.draggedId) { return; }
    const touch = event.fingerList[0];
    this.dragOffsetX = touch ? touch.globalX - this.dragStartX : event.offsetX;
    this.dragOffsetY = touch ? touch.globalY - this.dragStartY : event.offsetY;
  }

  private cancelDrag(): void {
    this.draggedId = undefined;
    this.dragOffsetX = 0;
    this.dragOffsetY = 0;
  }

  private dropTarget(source: DevToolsBuiltinId, windowX: number, windowY: number): DevToolsBuiltinId | undefined {
    const ui = this.getUIContext();
    const x = ui.vp2px(windowX);
    const y = ui.vp2px(windowY);
    for (const group of DEVTOOLS_GROUPS) {
      for (const tool of this.settings.tools(group, true)) {
        const id = tool.id;
        if (id === source) { continue; }
        try {
          const rect = ui.getComponentUtils().getRectangleById(`devtools_manage_${id}`);
          if (x >= rect.windowOffset.x && x < rect.windowOffset.x + rect.size.width &&
            y >= rect.windowOffset.y && y < rect.windowOffset.y + rect.size.height) { return id; }
        } catch { /* The target may have left the window during the gesture. */ }
      }
    }
    return undefined;
  }

  private finishDrag(event: GestureEvent): void {
    const source = this.draggedId;
    if (!source) { return; }
    const touch = event.fingerList[0];
    try {
      const target = this.dropTarget(source, touch?.globalX ?? (this.dragStartX + this.dragOffsetX),
        touch?.globalY ?? (this.dragStartY + this.dragOffsetY));
      if (target && this.settings.move(source, target) === 'lastInGroup') {
        this.getUIContext().getPromptAction().showToast({ message: '分组中必须存在一个元素' });
      }
    } catch { /* A closed host window no longer has a drop target. */ }
    finally {
      this.cancelDrag();
    }
  }

  @Builder
  private managerGroup(group: DevToolsBuiltinGroup) {
    if (this.settings.tools(group, true).length > 0) {
      Column() {
        DevToolsCatalogHeading({ groupName: groupTitle(group) })
        Flex({ wrap: FlexWrap.Wrap }) {
          Repeat<DevToolsCatalogEntry>(this.settings.tools(group, true).map(builtinTool))
            .each((entry: RepeatItem<DevToolsCatalogEntry>): void => {
              Stack() {
                DevToolsCatalogIcon({ tool: entry.item })
                if (this.settings.editing) {
                  Stack({ alignContent: Alignment.TopEnd }) {
                    Image(entry.item.checked ? $r('app.media.devtools_checked') : $r('app.media.devtools_unchecked'))
                      .width(14)
                      .height(14)
                      .draggable(false)
                      .margin(6)
                    if (!entry.item.checked) {
                      Row().width('100%').height('100%').backgroundColor('#99EEEEEE')
                    }
                  }
                  .width('100%')
                  .height('100%')
                  .hitTestBehavior(HitTestMode.None)
                }
              }
              .width('25%')
              .height(100)
              .backgroundColor(this.draggedId === entry.item.id ? '#F5F5F5' : Color.White)
              .borderWidth({ right: '1px', bottom: '1px' })
              .borderColor(LINE_COLOR)
              .translate({ x: this.draggedId === entry.item.id ? this.dragOffsetX : 0,
                y: this.draggedId === entry.item.id ? this.dragOffsetY : 0 })
              .zIndex(this.draggedId === entry.item.id ? 1 : 0)
              .onTouch((event: TouchEvent): void => {
                if (event.type === TouchType.Down) { this.suppressTap = false; }
              })
              .onClick((): void => {
                const id = entry.item.builtinId;
                if (id && !this.suppressTap) { this.settings.toggle(id); }
              })
              .priorityGesture(GestureGroup(GestureMode.Sequence,
                LongPressGesture({ duration: 500 })
                  .onAction((event: GestureEvent): void => this.beginDrag(entry.item.builtinId, event)),
                PanGesture({ distance: 3 })
                  .onActionStart((event: GestureEvent): void => this.updateDrag(event))
                  .onActionUpdate((event: GestureEvent): void => this.updateDrag(event))
                  .onActionEnd((event: GestureEvent): void => this.finishDrag(event))
              ).onCancel((): void => this.cancelDrag()))
              .accessibilityGroup(true)
              .accessibilityText(entry.item.title)
              .accessibilityChecked(this.settings.editing && entry.item.checked)
              .id(`devtools_manage_${entry.item.id}`)
            })
            // Recreate the cell when its check mark changes, including its accessibility state.
            .key((tool: DevToolsCatalogEntry): string => `${tool.id}:${tool.checked}`)
        }
        .width('100%')
      }
      .width('100%')
      .zIndex(this.settings.tools(group, true).some((tool: DevToolsBuiltinSetting): boolean => tool.id === this.draggedId) ? 1 : 0)
    }
  }

  build() {
    Stack() {
      Column() {
        DevToolsCatalogBar({ manager: true, editing: this.settings.editing,
          onBack: (): void => { if (!this.settings.requestManagerBack()) { this.onBack(); } },
          onRight: (): void => this.toggleEditing(), onReset: (): void => this.settings.requestReset() })
        Scroll() {
          Column() {
            this.managerGroup('common')
            this.managerGroup('performance')
            this.managerGroup('visual')
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      if (this.settings.dialog !== 'none') {
        DevToolsManagerDialogView({ settings: this.settings, onBack: this.onBack })
      }
    }
    .width('100%')
    .height('100%')
    .id('devtools_manager_page')
  }
}
