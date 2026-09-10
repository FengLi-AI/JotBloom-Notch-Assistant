# 萌生图标

`AppIcon-source.png` 为 2026-09-10 用户确认的生成图标原图：蓝白刘海轮廓与萌芽组合。保留原有透明背景与设计，不重新绘制。

运行 `bash scripts/build-app-icon.sh`，使用 macOS sips 与 iconutil 导出 16、32、128、256、512 点的 1x/2x 图标资源，生成 `JotBloom/Resources/AppIcon.icns`。图标由工程资源阶段嵌入，Info.plist 的 CFBundleIconFile 指向 AppIcon.icns。

macOS 不同版本可能对 App 图标应用系统底板或视觉样式，因此运行时外观以系统渲染为准。
