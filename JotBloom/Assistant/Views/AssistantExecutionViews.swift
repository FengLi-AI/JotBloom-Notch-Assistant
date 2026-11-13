import AppKit
import JotBloomCore
import SwiftUI

struct AssistantExecutionActionView: View {
    @ObservedObject var model: AssistantViewModel
    let task: AssistantTask
    @State private var question: AssistantRuntimeQuestion?
    @State private var selected: Set<String> = []
    @State private var answer = ""
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if task.status == .waitingUser, let question, question.agent != nil {
                AssistantAgentQuestionView(model: model, taskID: task.id, question: question).id(question.id)
            } else if task.status == .waitingUser, let question {
                Text(question.text).font(BloomTypography.font(13, role: .label)).fixedSize(horizontal: false, vertical: true)
                ForEach(question.candidates) { item in
                    Toggle(item.title, isOn: Binding(get: { selected.contains(item.id) }, set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } }))
                        .font(BloomTypography.font(12))
                }
                if ["runtimeClarify", "supervision"].contains(question.kind) {
                    TextField("补充你的想法", text: $answer, axis: .vertical).textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 8) {
                    if question.kind != "runtimeClarify" {
                        Button(question.kind == "scope" ? "不用了" : question.kind == "budget" ? "先到这里" : "停止") { respond(false) }.buttonStyle(BloomButtonStyle())
                    }
                    if question.kind == "codexResult" {
                        Button("确认完成") { perform { try await model.coordinator.answerExecution(task.id, question: question.id, allow: true, answer: "completed") } }.buttonStyle(BloomButtonStyle())
                    }
                    Spacer(minLength: 12)
                    Button(question.scopeKind == "materials" ? "用选中的" : question.kind == "scope" ? "允许" : question.kind == "supervision" ? (answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "按原目标继续" : "按补充继续") : "继续") { respond(true) }
                        .buttonStyle(BloomButtonStyle(primary: true))
                        .disabled((question.scopeKind == "materials" && selected.isEmpty) || (question.kind == "runtimeClarify" && answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            } else if task.status == .interrupted {
                Text("进度和结果已保留，继续时会先检查结果不明的操作。")
                HStack { Button("结束") { perform { _ = await model.cancel(task.id) } }.buttonStyle(BloomButtonStyle()); Spacer()
                    Button("继续") { perform { try await model.coordinator.continueExecution(task.id) } }.buttonStyle(BloomButtonStyle(primary: true)) }
            } else if task.status == .running {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在推进，你可以继续聊天。") }
            } else if task.status == .queued { Text("排队中，前一件事处理完或等你回答后就会继续。")
            } else if task.status == .failed { Text("本次未能完成，已有结果和进度保留。") }
        }.font(BloomTypography.font(12)).disabled(busy)
            .task(id: task.updatedAt) {
                let next = try? await model.coordinator.executionDetails(task.id).question
                if next?.id != question?.id { selected = []; answer = "" }
                question = next
            }
    }
    private func respond(_ allow: Bool) {
        guard let question else { return }
        perform { try await model.coordinator.answerExecution(task.id, question: question.id, allow: allow, selected: selected, answer: answer) }
    }
    private func perform(_ operation: @escaping () async throws -> Void) {
        busy = true
        Task { defer { busy = false }; do { try await operation() } catch { model.feedback = error.localizedDescription } }
    }
}

struct AssistantExecutionDetailView: View {
    @ObservedObject var model: AssistantViewModel
    let task: AssistantTask
    var onCopy: (String) -> Bool
    @State private var steps: [AssistantExecutionStep] = []
    @State private var materials: [AssistantMaterialUsage] = []
    @State private var files: [AssistantResultFile] = []
    @State private var allEvents = false
    @State private var supplement = ""
    @State private var saving: Set<String> = []
    @State private var agentSession: AgentSession?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !materials.isEmpty {
                DisclosureGroup("任务资料 · \(materials.count) 条，已发送 \(materials.filter(\.sent).count) 条") {
                    VStack(alignment: .leading, spacing: 8) {
                    ForEach(materials) { material in
                        HStack(alignment: .top, spacing: 10) {
                            Text(material.attachment.title).lineLimit(2)
                            Spacer(minLength: 12)
                            Text(material.sent ? "已发送" : material.selected ? "已允许，尚未发送" : "未发送")
                                .font(BloomTypography.font(10)).foregroundStyle(BloomTheme.muted)
                        }
                    }
                    Text("单条资料最多发送 8000 字符，整个任务累计最多 40000 字符；超出会截断并记录。")
                        .font(BloomTypography.font(10)).foregroundStyle(BloomTheme.muted)
                    }.padding(.top, 10)
                }.font(BloomTypography.font(12))
            }
            if let agentSession, agentSession.threadID != nil { AssistantSupervisionView(model: model, session: agentSession, completed: task.status == .completed) }
            if !importantEvents.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    label("关键进展")
                    ForEach(Array(importantEvents.prefix(allEvents ? importantEvents.count : 3))) { event in
                        HStack(alignment: .top, spacing: 12) {
                            Text("· " + event.text).foregroundStyle(BloomTheme.muted).lineLimit(allEvents ? nil : 2).textSelection(.enabled)
                            Spacer(minLength: 8)
                            if let step = steps.first(where: { event.kind == "step:\($0.id)" && $0.undo != nil }) {
                                if step.undone { Text("已撤销").font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted) }
                                else { Button("撤销") { run { try await model.coordinator.undoExecution(task.id, step: step.id) } }.buttonStyle(.plain).foregroundStyle(BloomTheme.blue) }
                            }
                        }
                    }
                    if importantEvents.count > 3 { Button(allEvents ? "收起记录" : "展开关键记录") { allEvents.toggle() }.buttonStyle(.plain).foregroundStyle(BloomTheme.blue) }
                }
            }
            if let summary = task.resultSummary { VStack(alignment: .leading, spacing: 8) { label("结果"); Text(summary).textSelection(.enabled) } }
            if let agentSession, !agentSession.lastReply.isEmpty {
                if task.status.isTerminal { DisclosureGroup("Codex 最后汇报") { Text(agentSession.lastReply).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) } }
            }
            if let work = task.scope?.workingDirectory {
                HStack(alignment: .top) { Text("工作文件夹").font(BloomTypography.font(12, role: .label)); Text(work).lineLimit(2).truncationMode(.middle).foregroundStyle(BloomTheme.muted); Spacer(minLength: 8)
                    Button("在访达中显示") { run { try await AssistantExternalActions.reveal(URL(fileURLWithPath: work), handoff: model.onExternalHandoff) } }.buttonStyle(.plain).foregroundStyle(BloomTheme.blue) }
            }
            if let agentSession, !agentSession.changedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    label("修改的工作文件")
                    ForEach(agentSession.changedFiles, id: \.self) { path in
                        HStack { Text(path).lineLimit(2).truncationMode(.middle).textSelection(.enabled); Spacer(minLength: 8)
                            Button("访达") { run { try await AssistantExternalActions.reveal(URL(fileURLWithPath: path), handoff: model.onExternalHandoff) } }.buttonStyle(.plain).foregroundStyle(BloomTheme.blue) }
                    }
                    Text("命令产生的修改以 Codex 汇报为补充，请在项目中核对。") .foregroundStyle(BloomTheme.muted)
                }
            }
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    label("结果文件 · \(files.count)")
                    ForEach(files) { file in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(file.name).font(BloomTypography.font(13, role: .label)).lineLimit(2)
                            if AssistantResultFiles.imageExtensions.contains(file.url.pathExtension.lowercased()) {
                                AssistantResultImageView(model: model, taskID: task.id, file: file, revision: task.updatedAt)
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) { fileActions(file) }
                                VStack(alignment: .leading, spacing: 8) { fileActions(file) }
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).modifier(BloomSurface(color: BloomTheme.well, radius: 12))
                    }
                }
            }
            if !task.status.isTerminal || (task.status == .completed && agentSession?.threadID != nil) {
                VStack(alignment: .leading, spacing: 8) {
                    label(task.status == .completed ? "继续修改" : "补充要求")
                    TextField("补充方向或说明，权限仍以已确认范围为准", text: $supplement, axis: .vertical).textFieldStyle(.roundedBorder)
                    HStack { Spacer(); Button("补充给助手") { run { if task.status == .completed { try await model.coordinator.continueCompleted(task.id, text: supplement) } else { try await model.coordinator.supplementExecution(task.id, text: supplement) }; supplement = "" } }
                            .buttonStyle(BloomButtonStyle()).disabled(supplement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
            }
        }.font(BloomTypography.font(12))
            .task(id: task.updatedAt) { await reload() }
    }
    @ViewBuilder private func fileActions(_ file: AssistantResultFile) -> some View {
        Button("打开文件") { run { try await validate(file); try AssistantExternalActions.open(file.url, handoff: model.onExternalHandoff) } }
        Button("在访达中显示") { run { try await validate(file); try await AssistantExternalActions.reveal(file.url, handoff: model.onExternalHandoff) } }
        if AssistantResultFiles.supportsTextActions(file.name) {
        Button("复制") { run { _ = onCopy(try await model.coordinator.readExecutionResult(task.id, name: file.name)) } }
        if task.status.isTerminal {
            Button(saving.contains(file.name) ? "保存中…" : "存入灵感库") {
                saving.insert(file.name)
                run { defer { saving.remove(file.name) }; try await model.coordinator.saveExecutionResult(task.id, name: file.name); model.feedback = "已存进灵感，可在进度记录里撤销。" }
            }.disabled(saving.contains(file.name))
        }
    }
    }
    private var importantEvents: [AssistantTaskEvent] {
        let routine: Set<String> = ["Codex 已完成一项操作。", "Codex 已处理一项文件修改。", "Codex 已更新任务说明。", "Codex 正在查阅网页。"]
        let codex = agentSession?.threadID != nil
        var previous = ""
        return model.events.filter { event in
            guard !routine.contains(event.text), !(event.kind == "agent" && event.text.hasPrefix("Codex 已更新计划")), event.kind != "supervision" else { return false }
            if codex {
                if event.kind == "completed" || event.text == task.resultSummary { return false }
                if let step = steps.first(where: { event.kind == "step:\($0.id)" }), step.undo == nil,
                   [.listResults, .readResult, .finish].contains(step.action.tool) { return false }
                guard event.text != previous else { return false }
                previous = event.text
            }
            return true
        }
    }
    private func validate(_ file: AssistantResultFile) async throws {
        let current = try await model.coordinator.executionDetails(task.id).files
        guard current.contains(file) else { throw ExecutionError.unreadable("文件已经变更，请刷新结果后重试。") }
    }
    private func label(_ text: String) -> some View { Text(text).font(BloomTypography.font(12, role: .label)) }
    private func reload() async {
        do { let details = try await model.coordinator.executionDetails(task.id); steps = details.steps; materials = details.materials.filter { $0.selected || $0.sent }; files = details.files; agentSession = try await model.coordinator.agentDetails(task.id) }
        catch { model.feedback = error.localizedDescription }
    }
    private func run(_ operation: @escaping () async throws -> Void) {
        Task { do { try await operation(); await reload(); await model.loadDetail(task.id) } catch { model.feedback = error.localizedDescription } }
    }
}
