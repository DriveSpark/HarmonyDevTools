# HarmonyDevTools

HarmonyOS 应用内开发工具箱，适用于 API 20 及以上的 ArkUI Stage 应用。点悬浮锤子可以查看设备、屏幕和应用信息，筛选日志，查看崩溃记录和性能曲线，也可以使用标尺、取色器、控件检查和布局边框。宿主可注册自己的工具按钮。

## 集成

发布到 OpenHarmony 三方库中心仓后，可在使用方模块目录执行安装命令。

```shell
ohpm install com.ttxz.devtools
```

本地集成可直接使用 release HAR。使用方模块将 `com.ttxz.devtools` 指向 HAR 文件，在全屏 `Stack` 中挂载 `DevToolsOverlay`，并将页面返回事件交给控制器。[完整接入示例](./devtools/README.md)

## 构建与验证

用 DevEco Studio 打开本仓库根目录。工程使用 HarmonyOS SDK 26，release HAR 最低兼容 API 20，包含 arm64-v8a 和 x86_64 两种原生库。在已安装对应工具链的 Windows 环境运行以下命令。

```powershell
.\build-har.ps1
node --test "tests/devtools-*.test.cjs"
```

可用 `-DevEcoHome` 指定 IDE 安装目录，测试可通过 `DEVECO_HOME` 找到该目录下的编译器。版本 `0.0.1` 的产物为 `build/outputs/release/com.ttxz.devtools-0.0.1.har`。

## 发布

维护者在 DevEco Studio Terminal 中使用 OHPM 预检生成的 HAR。预检通过并确认发布后，可将同一个文件提交到中心仓。发布身份和公钥需在中心仓账户中配置。[OHPM 官方发布说明](https://developer.huawei.com/consumer/cn/doc/harmonyOS-guides/ide-ohpm-publish/)

```powershell
ohpm prepublish .\build\outputs\release\com.ttxz.devtools-0.0.1.har
ohpm publish .\build\outputs\release\com.ttxz.devtools-0.0.1.har
```

项目采用 Apache-2.0 许可证。工具图标的上游版权和来源随 HAR 提供。[许可证](./LICENSE) · [图标清单](./devtools/src/main/resources/rawfile/devtools_artwork.txt) · [版本记录](./devtools/CHANGELOG.md)
