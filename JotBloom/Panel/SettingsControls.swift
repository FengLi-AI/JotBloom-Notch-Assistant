import AppKit
import JotBloomCore
import SwiftUI

struct SettingsControls: View {
    @ObservedObject var model: SettingsViewModel
    let section: String
    @State private var removingKey: ModelSlot?
    @State private var confirmingKeyRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch section {
            case "general": general
            case "clipboard": clipboard
            case "storage": storage
            case "ai": ai
            default: EmptyView()
            }
        }
        .font(.system(size: 12))
        .buttonStyle(BloomButtonStyle())
        .disabled(model.busy)
        .task(id: section) {
            if section == "clipboard" || section == "storage" { await model.refreshUsage() }
        }
        .alert("清空剪贴板历史？", isPresented: $model.confirmingClear) {
            Button("取消", role: .cancel) {}
            Button("清空历史", role: .destructive) { model.clearHistory() }
        } message: { Text(model.clearConfirmationMessage) }
        .alert("移除已保存的密钥？", isPresented: $confirmingKeyRemoval) {
            Button("取消", role: .cancel) {}
            Button("移除密钥", role: .destructive) { if let slot = removingKey { model.removeKey(slot) } }
        } message: { Text("移除后，该凭证不再用于连接测试。本地记录不受影响。") }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.showingOnboarding {
                card { Text("欢迎使用萌生").fontWeight(.medium); onboarding }
            } else {
            card {
                Text("全局唤起快捷键").fontWeight(.medium)
                HStack {
                    Text(model.value.shortcut.label).font(.system(size: 15, design: .monospaced))
                    Spacer()
                    Button(model.recordingShortcut ? "按下新组合，Esc 取消" : "录制快捷键") { model.recordingShortcut.toggle() }
                }
                note("新组合冲突时会保留旧快捷键；不要使用系统或文字编辑快捷键。")
            }
            card {
                Toggle("菜单栏显示图标", isOn: Binding(get: { model.value.showMenuBarIcon }, set: model.setMenuVisible))
                note("图标太多看不到时，用 \(model.value.shortcut.label) 呼出，再用齿轮进入设置；⌘Q 可退出。")
            }
            card {
                Toggle("开机自动启动", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                note(model.loginStatus)
                Button("打开系统登录项设置") { SMLoginSettings.open() }
                note("测试构建放在临时目录时不能开启，请先将 App 放到稳定位置。")
            }
            card {
                Text("使用说明").fontWeight(.medium)
                Button("重新查看首次引导") { model.reopenOnboarding() }
            }
            }
        }.toggleStyle(BloomToggleStyle())
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(model.onboardingStep + 1) / 3").foregroundStyle(BloomTheme.blue)
            Text(["用 \(model.value.shortcut.label) 或点击黑色刘海呼出萌生。再次操作可收起。",
                  "在灵感页随手记录，保存后在灵感库继续编辑。剪贴板历史可点击复制，也可本地搜索。",
                  "AI 是可选增强。可生成提示词标题、讨论想法；不填 Key 也能记录。主动发送对话时会发送消息及必要上下文，默认不会开机启动。 "][model.onboardingStep])
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("以后再说") { model.finishOnboarding() }
                Spacer()
                Button(model.onboardingStep == 2 ? "开始使用" : "下一步") {
                    if model.onboardingStep == 2 { model.finishOnboarding() } else { model.onboardingStep += 1 }
                }
            }
        }
    }

    private var clipboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                Toggle("剪贴板监听", isOn: Binding(get: { model.value.monitoringEnabled }, set: model.setMonitoring))
                    .toggleStyle(BloomToggleStyle())
                note("关闭后停止新增记录，已有历史保留。重新开启不会补录暂停期间复制的内容。")
            }
            card {
                Text("采集与保留").fontWeight(.medium)
                Picker("保留条数", selection: Binding(get: { model.value.maximumCount }, set: { model.setRetention(count: $0) })) {
                    ForEach(AppSettings.countOptions, id: \.self) { Text($0 == 0 ? "不限" : "\($0) 条").tag($0) }
                }
                Picker("保留时长", selection: Binding(get: { model.value.maximumDays }, set: { model.setRetention(days: $0) })) {
                    ForEach(AppSettings.dayOptions, id: \.self) { Text($0 == 0 ? "永久" : $0 == 365 ? "1 年（365 天）" : "\($0) 天").tag($0) }
                }
                Picker("容量上限", selection: Binding(get: { model.value.maximumBytes }, set: { model.setRetention(bytes: $0) })) {
                    ForEach(AppSettings.byteOptions, id: \.self) { Text($0 == 0 ? "不限" : Self.bytes($0)).tag($0) }
                }
                note("修改立即清理超限旧历史，无法撤销。容量超限会清至上限一半。敏感内容过滤始终开启。")
                Button("重新按当前规则清理") { model.setRetention() }
            }
            card {
                Text("当前用量").fontWeight(.medium)
                if let usage = model.usage {
                    Text("\(usage.count) 条历史 · 内容用量 \(Self.bytes(usage.contentBytes))")
                    note("数据库与图片磁盘占用 \(Self.bytes(usage.diskBytes))；数据库也包含灵感，不等于剪贴板容量计数。")
                } else { note("正在读取用量…") }
                HStack {
                    Button("刷新") { Task { await model.refreshUsage() } }
                    Button("清空历史记录") { model.prepareClearHistory() }
                }
                Button("重试残留图片清理") { model.retryCleanup() }
            }
        }
    }

    private var storage: some View {
        card {
            Text("更改保存位置").fontWeight(.medium)
            note("在所选文件夹下创建独立的 JotBloom 目录，复制并校验已有记录和图片后切换。旧目录保留迁移前副本，新内容只写入新位置。")
            if let usage = model.usage { note("当前数据库与图片约 \(Self.bytes(usage.diskBytes))，另含已有升级备份。迁移前会再次检查目标空间。") }
            Button("选择新位置并迁移…") { selectDirectory() }
            note("不合并已有库，不支持网络卷或云同步。迁移期间暂停写入，完成后自动恢复。")
        }
    }

    private var ai: some View {
        VStack(alignment: .leading, spacing: 16) {
            modelCard(.main)
            card {
                Toggle("辅助模型复用主模型地址与密钥", isOn: Binding(get: { model.value.auxiliaryUsesMain }, set: model.setAuxiliaryUsesMain)).toggleStyle(BloomToggleStyle())
                note("辅助模型用于提示词标题、灵感标题与分类；模型名留空时，整套使用主模型。对话与对话整理使用主模型。")
            }
            modelCard(.auxiliary)
            card {
                Text("哪些内容会发送给模型").fontWeight(.medium)
                note("测试连接：仅固定测试短句，不发送你的记录。")
                note("提示词标题：新保存的提示词会发送正文前 2000 字符；失败保留本地标题，后台不弹授权框。")
                note("灵感 AI 整理：默认关闭。开启后，仅处理之后新保存的灵感，发送原文前 2000 字符；不会自动扫描上传历史。详情中的“AI 整理”是你主动对该条重试。")
                note("AI 对话：主动发送时传递消息与必要上下文。整理成灵感：仅发送当前会话选取的已完成轮次，生成预览，确认后才保存。")
                note("不填 Key 也能使用本地记录、提示词、剪贴板和搜索。以上 AI 请求可能按服务商规则计费。")
            }
            note("打开本页不读取密钥。测试、对话和后台任务不自动弹系统密码框；访问异常时请查看对应模型的密钥访问帮助。辅助模型独立配置时，请也测试辅助模型。更改主模型配置或密钥会停止当前回复并保留已收到的内容。")
            note("密钥仅在系统钥匙串持久保存；会话内存副本不写入文件，退出后不保留。测试只发送固定短句，可能按服务商计费，不发送你的灵感和剪贴板内容。")
        }
    }
    private func modelCard(_ slot: ModelSlot) -> some View {
        card {
            Text(slot == .main ? "主模型" : "辅助模型").font(.system(size: 14, weight: .medium))
            if slot == .main || !model.value.auxiliaryUsesMain {
                field("接口地址（包含服务所需的 /v1 前缀）", text: slot == .main ? $model.mainURL : $model.auxiliaryURL)
            }
            field("模型名称", text: slot == .main ? $model.mainModel : $model.auxiliaryModel)
            if slot == .main || !model.value.auxiliaryUsesMain {
                HStack { Text("API Key"); Spacer(); note(model.keyDisplayStatus(slot)) }
                SecureField("输入新密钥以替换，留空保留原密钥", text: Binding(get: { model.keyInputs[slot] ?? "" }, set: { model.keyInputs[slot] = $0; model.configurationEdited() }))
                    .textFieldStyle(.plain).padding(10).background(BloomTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                    .onSubmit { model.saveKey(slot) }.accessibilityLabel("\(slot == .main ? "主" : "辅助")模型新 API Key")
                HStack {
                    Button("更新密钥") { model.saveKey(slot) }.disabled((model.keyInputs[slot] ?? "").isEmpty || model.readingCredential || !model.testing.isEmpty)
                    Button("移除密钥") { removingKey = slot; confirmingKeyRemoval = true }.disabled(model.readingCredential || !model.testing.isEmpty)
                }
            }
            let effective = model.previewConfiguration(for: slot)
            credentialRecoveryHelp(slot, credentialSlot: effective.credentialSlot)
            note("测试目标：\(effective.configuration.baseURL.isEmpty ? "尚未配置" : effective.configuration.baseURL)\n凭证来源：\(effective.credentialSlot == .main ? "主模型" : "辅助模型")")
            HStack {
                Button(model.testing.contains(slot) ? "正在测试…" : "测试连接") { model.testConnection(slot) }.disabled(model.readingCredential || !model.testing.isEmpty)
                if model.testing.contains(slot) { Button("取消") { model.cancelTests() } }
            }
            if let result = model.connectionStatus[slot] { note(result) }
            if model.credentialHelp.contains(slot) {
                note("本次未能读取密钥，没有发送测试请求。未配置时请填写 API Key；已有旧密钥时请展开“密钥访问帮助”，原密钥不会自动删除。")
            }
        }
    }
    private func credentialRecoveryHelp(_ slot: ModelSlot, credentialSlot: ModelSlot) -> some View {
            DisclosureGroup("密钥访问帮助（\(credentialSlot == .main ? "主模型" : "辅助模型")）") {
                VStack(alignment: .leading, spacing: 10) {
                    note("旧开发版条目可能需要重新授权。下面的按钮仅修复密钥访问，可能出现系统密码框；不会测试接口或自动重发消息。系统钥匙串被锁定时，请先在系统中解锁。")
                    Button("重新授权旧密钥…") { model.recoverKeyAccess(slot) }
                        .disabled(model.readingCredential || !model.testing.isEmpty)
                        .help("仅用户主动点击才申请旧钥匙串授权；不修改 Key，不发送模型请求")
                    note("当前仍为旧钥匙串兼容方案；正式版存储、签名与重启免授权尚待验证。不要为消除提示而删除正在使用的 Key。")
                }.padding(.top, 8)
            }
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(BloomTheme.muted)
            TextField(title, text: Binding(get: { text.wrappedValue }, set: { text.wrappedValue = $0; model.configurationEdited() }), onEditingChanged: { editing in if !editing { _ = model.commitModelEdits() } })
                .onSubmit { _ = model.commitModelEdits() }
                .textFieldStyle(.plain).padding(10).background(BloomTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(title)
        }
    }
    static func makeDirectoryPicker() -> NSOpenPanel {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false
        picker.canCreateDirectories = true
        picker.prompt = "选择位置"; picker.message = "将在此创建 JotBloom 子目录并迁移数据，现有非空目标不会被覆盖。"
        picker.level = .modalPanel
        return picker
    }
    private func selectDirectory() {
        guard model.beginDirectorySelection() else { return }
        let picker = Self.makeDirectoryPicker()
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { result in
            Task { @MainActor in
                guard result == .OK, let parent = picker.url else { model.endDirectorySelection(); return }
                let confirmation = NSAlert()
                confirmation.messageText = "迁移至此位置？"
                confirmation.informativeText = parent.appendingPathComponent("JotBloom").path + "\n复制并校验后切换，旧位置保留迁移前副本。后续新内容只写入新位置。"
                confirmation.addButton(withTitle: "开始迁移")
                confirmation.addButton(withTitle: "取消")
                let confirmed = confirmation.runModal() == .alertFirstButtonReturn
                model.endDirectorySelection()
                guard confirmed else { return }
                model.migrate(to: parent)
            }
        }
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content).frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).modifier(BloomSurface(color: BloomTheme.well))
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(BloomTheme.muted).fixedSize(horizontal: false, vertical: true)
    }
    private static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .decimal) }
}

struct SettingsOperationFeedback: View {
    @ObservedObject var model: SettingsViewModel
    var body: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.feedback ?? "普通设置即时生效；文字配置在提交或失焦后校验保存。")
                .font(.system(size: 11)).foregroundStyle(BloomTheme.muted).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if model.migrating { Button("取消迁移") { model.cancelMigration() }.buttonStyle(BloomButtonStyle()) }
        }.frame(minHeight: 28).accessibilityElement(children: .contain)
    }
}
