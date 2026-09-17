import AppKit
import JotBloomCore
import SwiftUI

struct PanelSettingsView: View {
    @ObservedObject private var extensions = ApplicationExtensionHost.shared
    @ObservedObject var state: PanelViewState
    let dataDirectory: URL?
    let onBack: () -> Void
    var model: SettingsViewModel? = nil
    @Environment(\.bloomReduceMotion) private var reduceMotion
    @State private var appearanceAnchor: NSView?
    private var sections: [(String, String, String)] {
        var items = [("general", "通用", "slider.horizontal.3"),
                            ("tabs", "顶部标签", "rectangle.3.group"),
                            ("clipboard", "剪贴板", "doc.on.clipboard"),
                            ("storage", "存储与隐私", "externaldrive"),
                            ("ai", "AI 接口", "sparkles"),
                            ("systemPrompt", "系统提示词", "text.bubble"),
                            ("about", "关于", "info.circle")]
        if let module = extensions.module {
            items.insert(("extensions", module.settingsTitle, "sparkles"), at: 1)
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Button(action: onBack) { BloomActionLabel(title: "返回", symbol: "chevron.left") }
                    .buttonStyle(BloomButtonStyle())
                Text("设置").font(BloomTypography.font(19, role: .label))
                Spacer()
                Text("让萌生适合你的习惯").font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
            }.bloomMeasure("settingsHeader")
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 8) {
                    VStack(spacing: 4) {
                    ForEach(sections, id: \.0) { section in
                        Button {
                            guard model?.maintaining != true else { return }
                            guard model?.allowLeavingPrompt() != false else { return }
                            if state.settingsSection == "ai" { model?.leaveSettings() }
                            model?.recordingShortcut = false
                            state.settingsSection = section.0
                        } label: {
                            BloomActionLabel(title: section.1, symbol: section.2)
                                .font(BloomTypography.font(12, role: .label)).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).frame(height: 42)
                                .foregroundStyle(state.settingsSection == section.0 ? Color.white : BloomTheme.muted)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    }
                    .background(alignment: .top) {
                        BloomSelectionSurface(radius: 12).frame(height: 42)
                            .offset(y: CGFloat(sections.firstIndex(where: { $0.0 == state.settingsSection }) ?? 0) * 46)
                            .animation(reduceMotion ? nil : BloomTheme.selectionAnimation, value: state.settingsSection)
                            .bloomMeasure("settingsSelection")
                    }
                    .padding(4).background(BloomTheme.shell, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Spacer()
                    Text("萌生 · JotBloom\n本地优先，随时记录")
                        .font(BloomTypography.font(10)).foregroundStyle(BloomTheme.muted).lineSpacing(5)
                }.frame(width: 124)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) { sectionContent }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(1)
                }
            }
            if let model { SettingsOperationFeedback(model: model) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BloomTheme.surface)
        .onDisappear { model?.leaveSettings() }
    }

    @ViewBuilder private var sectionContent: some View {
        switch state.settingsSection {
        case "extensions":
            if let module = extensions.module { module.settingsView }
        case "tabs":
            heading("顶部标签", "调整两侧排列；⌘1–6 跟随位置变化。未开放的标签仍保留位置。")
            VStack(spacing: 5) {
                ForEach(Array(state.preferences.order.enumerated()), id: \.element) { index, slot in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
                        BloomSymbol(slot.symbol).foregroundStyle(BloomTheme.blue).frame(width: 20)
                        Text(slot.title).font(BloomTypography.font(12, role: .label))
                        if !slot.isAvailable { Text("待开放").font(BloomTypography.font(10)).foregroundStyle(BloomTheme.muted) }
                        Spacer()
                        Button { state.preferences.move(slot, by: -1) } label: { BloomSymbol("chevron.up") }
                            .disabled(index == 0).help("前移\(slot.title)").accessibilityLabel("前移\(slot.title)")
                        Button { state.preferences.move(slot, by: 1) } label: { BloomSymbol("chevron.down") }
                            .disabled(index == 5).help("后移\(slot.title)").accessibilityLabel("后移\(slot.title)")
                    }.buttonStyle(BloomButtonStyle()).padding(9).modifier(BloomSurface(color: BloomTheme.well, radius: 14))
                }
            }
            defaultPicker
            Text("修改即时生效并保存；默认标签在下次呼出时生效。")
                .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
        case "clipboard":
            heading("剪贴板", "现有剪贴板采集规则保持不变。本页不读取或展示剪贴板内容。")
            if let model { SettingsControls(model: model, section: "clipboard") } else {
            pending("剪贴板监听", "当前正式功能仍在监听；暂停开关将在第六阶段接入。", symbol: "doc.on.clipboard")
            pending("采集与保留规则", "来源排除、保留上限等偏好将在后续阶段提供。", symbol: "line.3.horizontal.decrease.circle")
            }
        case "storage":
            heading("存储与隐私", "你的灵感与剪贴板历史保存在本机。")
            VStack(alignment: .leading, spacing: 10) {
                BloomActionLabel(title: "当前保存位置", symbol: "externaldrive").font(BloomTypography.font(13, role: .label))
                Text(model?.dataDirectory.path ?? dataDirectory?.path ?? "由应用的数据目录解析器管理")
                    .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted).textSelection(.enabled)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).modifier(BloomSurface(color: BloomTheme.well))
            if let model { SettingsControls(model: model, section: "storage") } else {
                pending("更改保存位置", "尚未接入迁移服务。", symbol: "folder")
            }
        case "about":
            AboutSettingsView()
        case "systemPrompt":
            heading("系统提示词", "调整 AI 对话方式。保存后仅新会话生效，已有会话保持原设置。")
            if let model { SystemPromptEditor(model: model) }
        case "ai":
            heading("AI 接口", "测试仅发送固定短句；新提示词可发送前 2000 字生成标题；主动对话会发送消息及必要上下文到主模型。")
            if let model { SettingsControls(model: model, section: "ai") } else {
            pending("服务地址与模型", "API 地址、模型选择和连接检查将在第六阶段接入。", symbol: "network")
            pending("API Key", "密钥将使用 macOS 钥匙串保存。本版不接收、不存储密钥。", symbol: "key")
            }
            if let model {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("灵感 AI 标题与分类", isOn: Binding(get: { model.value.inspirationAIEnabled }, set: model.setInspirationAI))
                        .toggleStyle(BloomToggleStyle())
                    Text("开启后，新保存灵感的前 2000 字符发送给辅助模型（未单独配置时使用主模型），可能产生费用。不会自动处理历史记录；可随时关闭。本地原文始终完整保存。")
                        .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
                }.padding(16).modifier(BloomSurface(color: BloomTheme.well))
            }
        default:
            heading("通用", "少一点打扰，多一点顺手。")
            appearanceSetting
            VStack(alignment: .leading, spacing: 8) {
                Text("快捷操作").font(BloomTypography.font(13, role: .label))
                Text("\(model?.value.shortcut.label ?? "⌥Space")  呼出 / 收起\n⌘↓ / ⌘↑  展开 / 收回\n⌘F  搜索    ⌘,  设置    ⌘Q  退出\nEsc  先退出设置或详情，再收起面板")
                    .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted).lineSpacing(7)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).modifier(BloomSurface(color: BloomTheme.well))
            defaultPicker
            Toggle(isOn: $state.preferences.reduceMotion) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("减少动态效果").font(BloomTypography.font(13, role: .label))
                    Text("关闭尺寸与展开动效；同时遵循系统辅助功能设置。")
                        .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
                }
            }.toggleStyle(BloomToggleStyle()).frame(maxWidth: .infinity, alignment: .leading)
                .padding(16).modifier(BloomSurface(color: BloomTheme.well))
            if let model { SettingsControls(model: model, section: "general") } else {
                pending("开机自动启动", "尚未接入系统登录项。", symbol: "power")
            }

        }
    }

    private var appearanceSetting: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("界面外观").font(BloomTypography.font(13, role: .label))
                Text("立即切换，自动记住你的选择").font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ForEach(PanelAppearance.allCases, id: \.self) { appearance in
                    Button {
                        guard state.preferences.appearance != appearance else { return }
                        if let anchor = appearanceAnchor, let action = state.onChangeAppearance {
                            action(appearance, anchor.convert(anchor.bounds, to: nil))
                        } else { state.preferences.appearance = appearance }
                    } label: {
                        BloomActionLabel(title: appearance == .dark ? "深色" : "浅色", symbol: appearance == .dark ? "moon" : "sun.max")
                            .font(BloomTypography.font(12, role: .label))
                            .foregroundStyle(state.preferences.appearance == appearance ? Color.white : BloomTheme.muted)
                            .frame(width: 78, height: 34).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(state.preferences.appearance == appearance ? .isSelected : [])
                    .accessibilityValue(state.preferences.appearance == appearance ? "当前外观" : "")
                }
            }
            .background(alignment: .leading) {
                BloomAccent(moving: true).frame(width: 78, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BloomTheme.buttonEdge, lineWidth: BloomTheme.buttonStroke))
                    .offset(x: state.preferences.appearance == .light ? 82 : 0)
                    .animation(reduceMotion ? nil : BloomTheme.selectionAnimation, value: state.preferences.appearance)
            }
            .background(BloomAppearanceAnchor { view in if appearanceAnchor !== view { appearanceAnchor = view } })
            .bloomMeasure("appearanceControl")
            .padding(4).background(BloomTheme.shell, in: RoundedRectangle(cornerRadius: 16))

        }.padding(16).modifier(BloomSurface(color: BloomTheme.well))
    }

    private var defaultPicker: some View {
        HStack(alignment: .top, spacing: 16) {
            Text("打开时的默认标签").font(BloomTypography.font(13, role: .label))
            Spacer(minLength: 0)
            Picker("打开时的默认标签", selection: $state.preferences.defaultSlot) {
                ForEach(state.preferences.order.filter(\.isAvailable), id: \.self) { slot in
                    Text(slot.title).tag(slot)
                }
            }.labelsHidden().font(BloomTypography.font(12, role: .label)).frame(width: 130).offset(y: -2)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).modifier(BloomSurface(color: BloomTheme.well))
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(BloomTypography.font(20, role: .label))
            Text(subtitle).font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 4)
    }

    private func pending(_ title: String, _ subtitle: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                BloomActionLabel(title: title, symbol: symbol).font(BloomTypography.font(13, role: .label))
                Spacer()
                Text("待接入").font(BloomTypography.font(10)).foregroundStyle(BloomTheme.muted)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(BloomTheme.raised, in: Capsule())
            }
            Text(subtitle).font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).modifier(BloomSurface(color: BloomTheme.well))
    }
}

private struct BloomAppearanceAnchor: NSViewRepresentable {
    var resolve: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        DispatchQueue.main.async { resolve(view) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
