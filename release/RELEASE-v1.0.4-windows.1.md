# 萌生 Windows 1.0.4 测试版

根据当前 Mac 1.0.4 延展 Windows 原生界面：深浅主题、MiSans 字体、同套 Tabler 图标、蓝紫弥散渐变按钮、细描边、二级导航、轻量滚动条及 1.5 秒主题圆形扩散。

- 设置 → 通用可切换外观，保存后下次启动沿用；减少动效设置继续生效。
- 对话和搜索自动展开，返回普通标签恢复此前大小；保留 Windows 顶部中央热区、托盘、Ctrl+Alt+Space 及恢复默认快捷键功能。
- 新默认提示词、固定产品约束与 Mac 同步；旧默认设置升级，自定义提示词与历史会话保留。
- 数据、凭据仍由 Windows 客户端独立保存，不新增同步、不向模型开放工具权限。

安装包：`JotBloom-1.0.4-Windows-x64-Setup.exe`，自包含 .NET Desktop Runtime，无需另外安装 SDK。适用于 Intel / AMD x64 的 Windows 10 22H2 / Windows 11。

验证：47 项核心检查、43 项存储检查、19 项共享契约检查通过。在 GitHub Windows runner 上完成 27 项原生界面检查，并验证 EXE 静默安装、安装文件 SHA256、安装后的 27 项界面检查和卸载。[查看本次构建与验证](https://github.com/FengLi-AI/JotBloom-Notch-Assistant/actions/runs/34895682520)。这些结果不替代 Windows 10 / 11 实机、多显示器和不同缩放比例的体验验收。

安装包未签名，系统可能提示核实来源。升级前退出旧版并备份重要数据。卸载保留用户内容和配置。此版为测试版，仍需要 Windows 实机的布局、DPI、快捷键和多显示器体验反馈。
