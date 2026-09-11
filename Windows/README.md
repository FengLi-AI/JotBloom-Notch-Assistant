# 萌生 Windows 客户端

版本：**1.0.3 测试版**。适配 Windows 10 22H2 / Windows 11，Intel / AMD x64。

基于 C#、.NET 10、WPF 和 Win32，提供灵感记录、剪贴板、提示词、灵感库、AI 对话、搜索及设置。鼠标紧贴屏幕顶部中央 300 DIP 宽的区域后出现提示条，点击呼出主面板；默认快捷键 `Ctrl+Alt+Space` 可直接呼出。

## 源码构建

安装 `global.json` 指定的 .NET 10 SDK，从 `Windows/` 目录执行：

```sh
dotnet run --project tests/JotBloom.Windows.Core.Tests/JotBloom.Windows.Core.Tests.csproj
dotnet run --project tests/JotBloom.Windows.Storage.Tests/JotBloom.Windows.Storage.Tests.csproj
python3 scripts/check-schema.py
dotnet publish src/JotBloom.Windows.Desktop/JotBloom.Windows.Desktop.csproj -c Release -r win-x64 --self-contained true -p:DebugType=None -p:DebugSymbols=false -o /path/to/publish
```

生成安装包需要 Python 3 和 NSIS 3.12：

```sh
python3 scripts/package.py /path/to/publish /path/to/output
```

安装包包含 .NET Desktop Runtime，不要求用户另外安装 SDK。安装程序以当前用户权限运行，安装和卸载前检查是否有正在运行的萌生进程。

## 数据与凭证

首次启动先选择业务数据父目录，再创建独立 `JotBloom/`，包含 SQLite V7 和 `Clipboard/`。配置目录 `%LOCALAPPDATA%\JotBloom\Windows\` 保存定位、设置及 DPAPI CurrentUser 加密凭证。卸载程序保留用户内容和配置。备份与迁移使用 SQLite Backup API，保留原目录；旧数据版本先备份再升级，不覆盖已有备份。

两端分别保存本地数据，本版本不提供跨设备同步或跨平台活动数据库共用。AI 接口及密钥由用户自行配置，第三方服务可能收费。

## 工程结构

- `src/JotBloom.Windows.Core/`：热区状态、动效、配置和 AI 协议。
- `src/JotBloom.Windows.Storage/`：SQLite、图片、草稿、库管理、会话及备份迁移。
- `src/JotBloom.Windows.Desktop/`：WPF 页面与 Windows 系统适配。
- `tests/`：使用临时目录和受控响应的契约检查。
- `licenses/`：分发依赖的许可原文。

已完成 42 项 Core/AI/设置检查、43 项 SQLite/文件检查和 19 个数据库结构对象对照；用户反馈 Windows 电脑安装与使用正常。该反馈不代表所有系统版本和设备均已覆盖。
