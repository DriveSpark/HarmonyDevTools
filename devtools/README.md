# HarmonyDevTools

HarmonyOS 应用内调试工具箱，适用于 API 20 及以上的 Stage 应用。点浮标进入全屏工具箱，拖动后浮标会吸附到最近的侧边并记住位置。

- 「常用工具 → 设备信息」展示品牌、制造商、型号、设备类型、系统和 API 版本、CPU 架构、整机内存，以及可用和总存储空间。
- 「常用工具 → 屏幕信息」展示宿主窗口所在屏幕的分辨率（px）、逻辑尺寸（vp）、屏幕方向、估算对角线尺寸、密度和刷新率。旋转屏幕或把窗口移到另一块显示屏时会更新。
- 「常用工具 → App信息」可以查看包名、应用版本、手机信息汇总和权限状态。查看设备和屏幕信息无需申请额外权限。
- 「性能监控 → CPU / 内存」分别控制当前进程的检测。开启后回到宿主仍可看到实时曲线。点曲线上的关闭图标可停止相应检测，「查看检测记录」可查看本次会话最近 120 个读数。内存使用 PSS，单位为 MiB。
- 「常用工具 → 日志」查看已接入进程产生的真实 HiLog。展开可搜索正文、Tag、PID，按最低等级和进程筛选。「只看当前应用」默认开启，通过完整 bundleName 匹配。收起为顶部一行后仍能操作宿主，并看到最新匹配日志。点击单条可展开全文，「导出全部」可把点击时已采集的日志保存到所选文件。
- 「性能监控 → Crash」默认关闭。开启后重新进入应用，仍会订阅系统交付的 JsError、NativeCrash。历史保留最近 30 条，按时间查看原因、PID 和系统提供的调用栈。清空仅影响本工具的历史。[系统崩溃事件字段](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/dfx/hiappevent-watcher-crash-events.md)
- 「视觉工具 → 取色器」可在宿主窗口拖动准星，读取像素坐标和 HEX 色值。放大镜显示准星附近的像素。每次按下或点「重新取样」都会重新抓取隐藏工具层后的画面。隐私窗口会显示不可用提示。
- 「视觉工具 → 控件检查」可点选或拖动定位，切换重叠的 ArkUI 节点，查看控件的位置和尺寸。「布局边框」叠加二维轮廓，宿主仍可正常操作。Web、Canvas 等自绘区域只能显示 ArkUI 暴露的宿主节点。
- 「常用工具 → 开发者选项」在开关已开启或状态不可读时先尝试直达。状态不可读且启动请求失败时，弹窗显示开启步骤，可重试「打开开发者选项」或选择「前往系统」。已确认开启的设备若无法直达，会先提示再打开上一级「系统」。已确认关闭时留在工具箱，显示开启步骤。系统接口会返回启动请求的结果，设置应用自行决定最终显示的页面。[开发者选项说明](https://developer.huawei.com/consumer/cn/doc/harmonyOS-guides/ide-developer-mode/) · [打开 UIAbility](https://developer.huawei.com/consumer/cn/doc/harmonyOS-references/js-apis-inner-application-uiabilitycontext/)
- 「视觉工具 → 对齐标尺」直接回到宿主页面。拖动十字准星可查看它到测量区域四边的像素距离。「包含状态栏高度」只调整上边读数。信息卡可以拖开，点卡片上的关闭按钮即可收起标尺。
- 「更多 → 功能管理」可调整内置工具的显示和顺序。宿主注册的按钮按指定分组出现在工具箱中，可以通过 `icon` 提供自己的图标。
- 「返回」收起面板。「退出 DevTools」还会隐藏这次的浮标，回到前台或重新进入宿主指定页面时恢复。已开启的检测可在曲线上单独关闭。面板底部显示当前 HAR 版本。

## 集成 HAR

包名为 `com.ttxz.devtools`。中心仓发布后，在使用方模块执行 `ohpm install com.ttxz.devtools`。本地也可以把构建出的 HAR 复制到使用方模块的 `libs`，按照下面的示例配置依赖，然后在使用方工程根目录执行 `ohpm install --all`。

```json
{
  "dependencies": {
    "com.ttxz.devtools": "file:./libs/com.ttxz.devtools-0.0.1.har"
  }
}
```

使用字节码 HAR 的宿主需要在工程 `build-profile.json5` 的目标 product 中设置 `buildOption.strictMode.useNormalizedOHMUrl` 为 `true`。将 `DevToolsOverlay` 放在全尺寸 `Stack` 的最后一个子项。宿主可选择开放工具的构建类型和页面。以下示例注册一个计数动作。

```typescript
import { DevToolsController, DevToolsOverlay } from 'com.ttxz.devtools';

@Entry
@ComponentV2
struct Index {
  @Local count: number = 0;
  @Local foreground: boolean = false;
  private readonly tools: DevToolsController = new DevToolsController();

  aboutToAppear(): void {
    this.tools.register({
      id: 'example.count',
      title: '增加计数',
      group: '示例工具',
      onSelect: (): void => { this.count++; }
    });
  }

  onPageShow(): void { this.foreground = true; }
  onPageHide(): void { this.foreground = false; }
  onBackPress(): boolean { return this.tools.handleBack(); }
  aboutToDisappear(): void { this.tools.dispose(); }

  build() {
    Stack() {
      Text(`已执行 ${this.count} 次`)
      DevToolsOverlay({ controller: this.tools, foreground: this.foreground, captureHiLog: true })
    }.width('100%').height('100%')
  }
}
```

`register()` 返回当次注册的注销函数。同一标识以最新注册为准。点击自定义动作后，工具箱退出才调用 `onSelect`。系统返回交给 `handleBack()` 逐层返回，`close()` 可直接收起整个工具箱。每个宿主窗口持有独立控制器，窗口销毁时调用 `dispose()`。

将宿主前后台状态传给 `foreground`，检测会在进入后台时暂停，并在回到前台时继续。宿主可以单独设置 `launcherVisible` 来控制哪些页面显示浮标，保持组件挂载即可跨页面观察已开启的曲线。

日志采集由宿主显式开启。示例的 `captureHiLog: true` 从组件挂载时开始采集，可以只在调试构建挂载该组件。若要记录更早的初始化日志，或在独立进程记录日志，可在相应进程的 Ability 初始化时创建 `DevToolsLogSource` 并调用 `start(this.context)`，在对应生命周期结束时调用 `dispose()`。同进程的窗口共享采集。系统每个进程只有一个原生 HiLog 回调，接入前请确认进程中其他组件没有占用 `OH_LOG_SetCallback`。普通应用可读取本工具主动接入、共享沙箱的进程日志。关闭包名过滤会展示全部已采集来源。以上功能无需新增系统权限。

## 从源码构建

在 Windows 上安装 DevEco Studio 和 HarmonyOS SDK 26 后，在 HarmonyDevTools 仓库根目录运行以下命令。若 DevEco Studio 安装在其他位置，可通过 `-DevEcoHome` 指定目录。

```powershell
.\build-har.ps1
```

脚本将字节码 HAR 输出到 `build/outputs/release/com.ttxz.devtools-0.0.1.har`。分发时只需提供这一个文件。包内带有本接入说明、arm64-v8a 和 x86_64 的原生日志库，最低兼容 API 20。日志环形缓存最多保留当前采集会话的 10,000 条记录。

## 开源许可与图标来源

本模块采用 Apache-2.0。蓝底白锤悬浮入口及「设备信息」「屏幕信息」两个工具图标均为原创 SVG。[模块许可证](./LICENSE)

工具箱内的 22 张功能图标取自滴滴 DoKit Android 3.7.11。图片仅更改了文件名。HAR 随附文件名对照、原版权声明和完整上游许可证。[图标清单](./src/main/resources/rawfile/devtools_artwork.txt) · [随包的上游许可证](./src/main/resources/rawfile/devtools_dokit_license.txt) · [上游发布源码](https://github.com/didi/DoKit/tree/5500b5041ff3992604212e97bb754acd972d25a8/Android/dokit/src/main/res/mipmap-xxhdpi)
