# 1.0.4 UI 与提示词基准

本版按用户在 2026-09-14 至 15 日确认的本地 Mac 双主题版本迭代，替代早期界面规范中“不加载自定义字体、不提供主题开关、不使用渐变”的视觉限制。既有存储、凭据、草稿、快捷键及平台入口契约延续。

Windows 保持 WPF / Win32 实现，采用相同配色、MiSans / Tabler 资源和交互语义，按 Windows 布局与 DIP 尺寸适配。没有将 Mac 截图当作 Windows 实测效果。官网截图来自本地原生 Mac 窗口与隔离的演示数据，AI 对话为固定演示内容。

WPF 动画与字体资源实现参考 [Microsoft 动画文档](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/graphics-multimedia/animation-overview) 和 [Pack URI 文档](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/app-development/pack-uris-in-wpf)。主题使用共享语义画刷更新现有控件；保留编辑内容，不通过重建整个应用切换配色。

预设系统提示词为可编辑行为偏好。固定产品约束独立拼入 system 消息，覆盖对话及辅助任务；请求不注册 tools，无自主工具执行循环。标题、分类、摘要材料作为数据处理。
