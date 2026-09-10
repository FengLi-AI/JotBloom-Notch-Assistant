# 萌生｜JotBloom

给闪过的想法，一点空间。

一个适配 **Mac 与 Windows** 的免费屏幕顶部小工具，为轻度创作和日常电脑办公设计：随手记录灵感、找回复制过的内容、收藏常用提示词，再与 AI 继续讨论想法。

[访问官网](https://fengli-ai.github.io/JotBloom-Notch-Assistant/) · [版本说明](https://github.com/FengLi-AI/JotBloom-Notch-Assistant/releases)

![萌生灵感记录界面](site/assets/inspiration.png)

## 能做什么

- **随手记灵感**：从屏幕顶部或快捷键呼出（Mac 默认 `⌥ Space`，Windows 默认 `Ctrl+Alt+Space`），快速记录；支持查重、分类、拖动排序。开启灵感 AI 后可辅助分类和生成短标题。
- **回看剪贴板**：查找复制过的文字、链接和图片；左键复制并收起，右键复制并保留面板。监听可以关闭，历史可以清空。
- **复用提示词**：编辑、保存、另存、收藏常用和拖动排序；配置 AI 后可自动生成短标题。
- **和 AI 讨论**：使用自己的模型接口，保存对话历史，将讨论整理为灵感；可调整系统提示词。
- **一起搜索**：搜索灵感、剪贴板和提示词，再按结果分类查找。
- **按习惯设置**：调整快捷键、顶部标签、默认入口和数据保存位置。

本次更新：新增 Windows 客户端。两端均可使用灵感记录、剪贴板、提示词、搜索、AI 对话及完整设置；Windows 通过顶部中央提示条或快捷键呼出。

目前不包含文件中转站、跨设备同步或自动更新器。

## 下载与安装

萌生免费使用，安装包可从[官网](https://fengli-ai.github.io/JotBloom-Notch-Assistant/)选择系统下载。

| 平台 | 版本 | 系统与架构 |
| --- | --- | --- |
| Mac | 1.0.2 | macOS 13+，Apple Silicon / Intel |
| Windows | 1.0.2 测试版 | Windows 10 22H2 / Windows 11，Intel / AMD 64 位 |

Mac 打开 DMG 后，将 **萌生｜JotBloom.app** 拖入“应用程序”；Windows 双击 EXE 完成安装。首次启动会请你选择数据保存位置。更新前保存内容并退出旧版，保留重要数据备份。

Mac 安装包使用 ad-hoc 签名，尚未经过 Apple 公证；Windows 安装包尚未签名，系统可能提示核实来源。请从项目官网或 Releases 下载，按系统指引安装。Mac 最低系统及 Intel 设备仍需更多兼容性反馈；Windows 已收到用户安装与使用正常的反馈。


## 本地数据与 AI

无需配置 AI 即可使用本地记录、剪贴板、提示词管理和搜索。AI 功能需要自己的兼容接口及 API Key，第三方服务商可能收费。

新用户首次启动先选择数据保存位置；已有用户升级保留原位置，仅卸载 App 后重装不会重复选择。记录保存在本机，Mac 的 API Key 使用系统钥匙串；Windows 使用当前用户的系统保护加密保存。AI 对话、自动命名、分类和整理会按功能需要将相应文本发送至你配置的服务。剪贴板监听默认开启，可随时关闭；请不要将敏感信息长期留在历史中。

更多说明：[数据与 AI](release/PRIVACY.md)。

## 从源码构建

使用 Xcode。仓库已包含 Xcode 工程，可直接打开 `JotBloom.xcodeproj` 或运行：

```sh
xcodebuild -project JotBloom.xcodeproj -scheme JotBloom -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY=- build
```

修改 `project.yml` 后，使用 XcodeGen 2.46 或更新版本运行 `xcodegen generate`。测试目标需要 macOS 14 或更新版本：

```sh
xcodebuild -project JotBloom.xcodeproj -scheme JotBloom -destination 'platform=macOS' CODE_SIGN_IDENTITY=- test
```

本地打包：`bash scripts/package-preview.sh 新的绝对输出目录`。脚本不会自动安装、启动或上传应用。

Windows 源码位于 `Windows/`，使用 .NET 10 SDK：

```sh
cd Windows
dotnet publish src/JotBloom.Windows.Desktop/JotBloom.Windows.Desktop.csproj -c Release -r win-x64 --self-contained true -p:DebugType=None -p:DebugSymbols=false -o /path/to/publish
```

完整构建与打包入口见 [Windows 源码说明](Windows/README.md)。

官网位于 `site/`，为不依赖构建工具的静态 HTML / CSS / JavaScript。GitHub Pages 从独立的官网发布分支提供访问，不上传开发资料或真实用户记录。

## 作者与反馈

李烽立｜Li Fengli

- 邮箱：qq204407676@gmail.com
- 微信：feNgL1999_
- 电话：+86 18580676433
- 小红书：[FengLiAi](https://www.xiaohongshu.com/user/profile/69b6dd97000000003303a64d)
- 抖音号：N24642464（在抖音内搜索）

欢迎家人们下载体验，帮我点点 Star。遇到 Bug，或者有更好的建议，欢迎提交 Issue、发邮件或私信我，感谢大家支持！

## 开源许可

[MIT License](LICENSE) · Copyright © 2026 Li Fengli。第三方与平台资源说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
