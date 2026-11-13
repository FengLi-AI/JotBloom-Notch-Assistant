import AppKit
import JotBloomCore
import SwiftUI

struct AssistantAgentQuestionView: View {
    @ObservedObject var model: AssistantViewModel
    let taskID: String
    let question: AssistantRuntimeQuestion
    @State private var answers: [String: String] = [:]
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.text).font(BloomTypography.font(13, role: .label)).fixedSize(horizontal: false, vertical: true)
            if let request = question.agent {
                ForEach(request.questions) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.text).textSelection(.enabled)
                        if !item.options.isEmpty {
                            Picker("可选答案", selection: Binding(get: { answers[item.id, default: ""] }, set: { answers[item.id] = $0 })) {
                                Text("请选择，或填写下方内容").tag("")
                                ForEach(item.options, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        TextField("你的回答", text: Binding(get: { answers[item.id, default: ""] }, set: { answers[item.id] = $0 }), axis: .vertical).textFieldStyle(.roundedBorder)
                    }
                }
                if !request.detail.isEmpty {
                    DisclosureGroup("查看详情") {
                        ScrollView { Text(request.detail).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180).padding(.top, 8)
                    }
                }
                if request.questions.isEmpty {
                    Text("只批准你看懂的操作；当前任务会话内允许不会改动全局配置。")
                        .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { actions(request) }
                    VStack(alignment: .leading, spacing: 10) { actions(request) }
                }
            }
        }.font(BloomTypography.font(12)).disabled(busy)
    }
    @ViewBuilder private func actions(_ request: AgentApproval) -> some View {
        Button("不允许") { send(.decline) }.buttonStyle(BloomButtonStyle())
        if request.allowsSession {
            Button("本次任务内允许") { send(.session) }.buttonStyle(BloomButtonStyle())
        }
        Button(request.questions.isEmpty ? "允许这一次" : "发送回答") { send(request.questions.isEmpty ? .once : .answer) }
            .buttonStyle(BloomButtonStyle(primary: true))
            .disabled(!request.questions.allSatisfy { !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }
    private func send(_ decision: AgentUserDecision) {
        busy = true
        Task { defer { busy = false }; do { try await model.coordinator.answerAgent(taskID, question: question.id, decision: decision, answers: answers) } catch { model.feedback = error.localizedDescription } }
    }
}

struct AssistantAgentSettingsView: View {
    @ObservedObject var coordinator: AssistantCoordinator
    @ObservedObject var settings: AssistantAgentSettings
    var onSystemInteraction: ((Bool) -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("助手与 Codex").font(BloomTypography.font(16, role: .label))
            Text(coordinator.agentAvailability.message).foregroundStyle(BloomTheme.muted)
            if let version = coordinator.agentAvailability.version { Text(version).font(BloomTypography.font(10)).foregroundStyle(BloomTheme.muted) }
            HStack(spacing: 10) {
                Button(coordinator.checkingAgent ? "检测中…" : "重新检测") { Task { await coordinator.checkAgent() } }.disabled(coordinator.checkingAgent)
                Button("选择 Codex…") { choose(directory: false) }
                if !settings.executable.isEmpty { Button("自动查找") { settings.executable = ""; Task { await coordinator.checkAgent() } } }
            }.buttonStyle(BloomButtonStyle())
            Picker("权限方式（新任务）", selection: $settings.mode) {
                Text("平衡模式").tag(AssistantPermissionMode.balanced)
                Text("每次都问我").tag(AssistantPermissionMode.askAlways)
            }
            Text(settings.mode == .balanced ? "确认范围内自动推进；额外批准交给你。已允许的网络权限仅授予当前轮次，并记录在进度里。" : "Codex 的额外批准和提问都交给你；新计划默认关闭自动找资料和联网。范围内的普通操作仍会自主执行。")
                .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) { Text("默认结果位置"); Text(settings.outputParent).foregroundStyle(BloomTheme.muted).lineLimit(2).truncationMode(.middle) }
                Spacer(minLength: 12); Button("选择…") { choose(directory: true) }.buttonStyle(BloomButtonStyle())
            }
            Divider()
            Toggle("安静模式", isOn: $settings.quiet).toggleStyle(BloomToggleStyle())
            Text("不主动弹出助手岛；待处理事项保留刘海微光或菜单栏圆点。任务和提醒照常记录，可随时打开任务列表查看。")
                .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
            Text("默认提醒时间").font(BloomTypography.font(13, role: .label))
            DatePicker("截止前一天", selection: reminderTime($settings.reminderDayBefore), displayedComponents: .hourAndMinute)
            DatePicker("截止当天", selection: reminderTime($settings.reminderSameDay), displayedComponents: .hourAndMinute)
            Text("用于新计划，以及改截止时间时重算自动提醒。更改设置不会立即移动已有提醒；手动改过、明确指定和执行中新增的提醒保留。不足 24 小时提前 2 小时，不足 2 小时提前 15 分钟，跳过已过去或晚于截止的自动提醒。计划卡可调整或关闭提醒，晚点再说顺延 1 小时。萌生退出或关机时不能提醒。")
                .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("派给 Codex 会发送确认的任务、完成标准和允许使用的资料，并使用你的 Codex 额度。Codex 可能读取勾选资料之外的本机文件；允许联网后可访问的网站不局限于你提供的链接。请按任务选择最小工作文件夹。萌生不会读取或保存 Codex 登录令牌。")
                .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted).fixedSize(horizontal: false, vertical: true)
            Text("当前派活只使用 Codex 的本机命令、文件和搜索能力，不接入原有插件或 MCP 工具。未允许联网时关闭搜索；这些限制只作用于萌生任务，不改你的 Codex 设置。")
                .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted).fixedSize(horizontal: false, vertical: true)
        }.font(BloomTypography.font(12)).padding(16).modifier(BloomSurface(color: BloomTheme.well))
    }
    private func reminderTime(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }
    private func choose(directory: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = directory; panel.canChooseFiles = !directory; panel.canCreateDirectories = directory
        panel.prompt = directory ? "选择结果位置" : "选择 Codex"
        onSystemInteraction?(true)
        panel.begin { response in
            defer { onSystemInteraction?(false) }
            guard response == .OK, let url = panel.url else { return }
            if directory { settings.outputParent = url.path } else { settings.executable = url.path; Task { await coordinator.checkAgent() } }
        }
    }
}
