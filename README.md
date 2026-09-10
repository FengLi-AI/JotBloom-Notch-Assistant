# 萌生｜JotBloom · 刘海屏助手

给闪过的想法，一点空间。

一个为轻度创作和日常电脑办公设计的 Mac 屏幕顶部小工具：随手记录灵感、找回复制过的内容、收藏常用提示词，再与 AI 继续讨论想法。

[访问官网](https://fengli-ai.github.io/JotBloom-Notch-Assistant/) · [下载 macOS 安装包](https://github.com/FengLi-AI/JotBloom-Notch-Assistant/releases/download/v1.0.0-preview.3/JotBloom-1.0.0-preview.3-universal.dmg) · [版本说明](https://github.com/FengLi-AI/JotBloom-Notch-Assistant/releases/tag/v1.0.0-preview.3) · [反馈 Bug / 建议](https://github.com/FengLi-AI/JotBloom-Notch-Assistant/issues)

![萌生灵感记录界面](site/assets/inspiration.png)

## 能做什么

- **随手记灵感**：从屏幕顶部或默认快捷键 `⌥ Space` 呼出，快速记录；支持查重、分类、拖动排序。开启灵感 AI 后可辅助分类和生成短标题。
- **回看剪贴板**：查找复制过的文字、链接和图片；左键复制并收起，右键复制并保留面板。监听可以关闭，历史可以清空。
- **复用提示词**：编辑、保存、另存、收藏常用和拖动排序；配置 AI 后可自动生成短标题。
- **和 AI 讨论**：使用自己的模型接口，保存对话历史，将讨论整理为灵感；可调整系统提示词。
- **一起搜索**：搜索灵感、剪贴板和提示词，再按结果分类查找。
- **按习惯设置**：调整快捷键、顶部标签、默认入口和数据保存位置。

本次更新：首次数据位置选择，以及快捷键录制预览、错误反馈与焦点修正。

目前不包含文件中转站、跨设备同步或自动更新器。后续计划支持 Windows。

## 下载与安装

当前版本为 **1.0.0-preview.3 公开预览版**，应用版本 1.0.0 / 构建 1103，安装包约 5.2 MB。

1. 从上方链接下载 DMG，必要时对照 Releases 中的 `SHA256SUMS.txt` 校验。
2. 打开 DMG，将 `萌生｜JotBloom.app` 拖到“应用程序”。
3. 从“应用程序”启动，不要长期从磁盘映像运行。
4. 升级前保存内容、退出旧版，并保留旧 App 和重要数据备份。

构建目标为 macOS 13 及以上，包含 Apple Silicon / Intel 双架构。**最低系统、Intel 真机及完整新装/升级权限体验仍待更多验证**，不保证所有设备兼容。本版已内置正式图标，系统名称为“萌生｜JotBloom”。

当前安装包使用 ad-hoc 签名，**未经过 Apple 公证**。系统可能显示安全提示；请核实下载来源，仅在信任后依照 [Apple 官方说明](https://support.apple.com/zh-cn/102445) 处理，不要关闭系统安全保护。受管理设备可能禁止启动。

首次使用、权限变更或升级后，钥匙串可能需要授权；打包不意味着所有情况下都不会出现系统授权提示。详见 [安装说明](release/INSTALL.md)。

## 本地数据与 AI

无需配置 AI 即可使用本地记录、剪贴板、提示词管理和搜索。AI 功能需要自己的兼容接口及 API Key，第三方服务商可能收费。

新用户首次启动先选择数据保存位置；已有用户升级保留原位置，仅卸载 App 后重装不会重复选择。记录保存在本机，API Key 使用 macOS 钥匙串。AI 对话、自动命名、分类和整理会按功能需要将相应文本发送至你配置的服务。剪贴板监听默认开启，可随时关闭；请不要将敏感信息长期留在历史中。

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
