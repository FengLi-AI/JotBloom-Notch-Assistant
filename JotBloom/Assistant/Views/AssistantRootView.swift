import JotBloomCore
import SwiftUI

enum AssistantRoute: Equatable {
    case conversation, tasks, detail(String, fromList: Bool)
}

struct AssistantRootView: View {
    @ObservedObject var model: AssistantViewModel
    @ObservedObject var chat: ChatViewModel
    @ObservedObject var panel: PanelViewState
    let onCopy: (String) -> Bool
    var body: some View {
        Group {
            switch panel.assistantRoute {
            case .conversation, .tasks:
                ChatView(model: chat, onCopy: onCopy, assistantModel: model,
                         assistantTasks: Dictionary(uniqueKeysWithValues: model.tasks.map { ($0.id, $0) }),
                         assistantLinks: model.links, savingTurns: model.savingTurns,
                         taskEntryTitle: model.coordinator.entryTitle, taskNeedsAttention: model.coordinator.attentionCount > 0,
                         showingTasks: panel.assistantRoute == .tasks,
                         onTaskList: {
                             guard chat.canLeaveChat() else { return }
                             if chat.showingHistory { chat.toggleHistory() }
                             panel.assistantRoute = panel.assistantRoute == .tasks ? .conversation : .tasks
                         },
                         onConvert: model.convert, onOpenTask: { panel.openAssistantTask(id: $0, fromList: panel.assistantRoute == .tasks) })
            case let .detail(id, fromList):
                TaskDetailView(model: model, taskID: id, onSettings: { chat.onOpenSettings?() },
                               onBack: { panel.assistantRoute = fromList ? .tasks : .conversation }, onCopy: onCopy)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let feedback = model.feedback {
                HStack {
                    Text(feedback).font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
                    Button("知道了") { model.feedback = nil }.buttonStyle(.plain)
                }.padding(12).background(BloomTheme.surface)
            }
        }
    }
}

struct TaskListView: View {
    @ObservedObject var model: AssistantViewModel
    let onOpen: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !model.coordinator.ready {
                        Text(model.coordinator.feedback ?? "正在读取任务…").foregroundStyle(BloomTheme.muted)
                        if model.coordinator.feedback != nil {
                            Button("重试") { Task { await model.coordinator.start() } }.buttonStyle(BloomButtonStyle())
                        }
                    } else if !model.tasks.contains(where: { $0.status.group != nil }) {
                        Text("还没有任务。在回答下方点“当任务办”，或把资料交给助手。")
                            .foregroundStyle(BloomTheme.muted).padding(.vertical, 20)
                    }
                    ForEach(AssistantTaskGroup.allCases) { group in
                        let tasks = model.tasks.filter { model.coordinator.group(for: $0) == group }
                        if !tasks.isEmpty {
                            Text("\(group.rawValue) \(tasks.count)").font(BloomTypography.font(11, role: .label))
                                .foregroundStyle(BloomTheme.muted).padding(.top, 8)
                            ForEach(tasks) { task in TaskTurnCardView(task: task, onOpen: { onOpen(task.id) }) }
                        }
                    }
                }.padding(.bottom, 44)
            }
        }
    }
}

struct TaskTurnCardView: View {
    let task: AssistantTask
    let onOpen: () -> Void
    private var dotColor: Color {
        if task.status == .completed { return IslandTheme.statusGreen }
        if task.status == .failed { return IslandTheme.statusRed }
        return task.status.group == .attention ? IslandTheme.statusOrange : BloomTheme.blue
    }
    var body: some View {
        if task.status == .cancelled {
            Text("已取消《\(task.title)》").font(BloomTypography.font(12)).foregroundStyle(BloomTheme.muted)
        } else {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                    Text(task.title).font(BloomTypography.font(13, role: .label)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(task.errorCode == "modelNotConfigured" ? "先配置模型" : task.status.title)
                        .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted).lineLimit(1)
                    BloomSymbol("chevron.right", size: 12).foregroundStyle(BloomTheme.muted)
                }.padding(.horizontal, 14).frame(height: 52).contentShape(Rectangle())
                    .modifier(BloomSurface(color: BloomTheme.well, radius: BloomTheme.controlRadius))
            }.buttonStyle(.plain).accessibilityLabel("\(task.title)，\(task.status.title)，查看任务")
        }
    }
}

struct TaskDetailView: View {
    @ObservedObject var model: AssistantViewModel
    let taskID: String
    let onSettings: () -> Void
    let onBack: () -> Void
    var onCopy: (String) -> Bool = { _ in false }
    @State private var allEvents = false
    @State private var deleting = false
    @State private var reminders: [AssistantReminder] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onBack) { BloomActionLabel(title: "返回", symbol: "chevron.left") }
                .buttonStyle(BloomButtonStyle()).frame(height: 32)
            if let task = model.task(taskID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top) {
                            Text(task.title).font(BloomTypography.font(18, role: .label)).textSelection(.enabled)
                            Spacer()
                            Text(task.status.title).font(BloomTypography.font(12)).foregroundStyle(BloomTheme.muted)
                        }
                        if !task.status.isTerminal || task.scope == nil {
                            AssistantTaskActionView(model: model, task: task, onSettings: onSettings).id(task.updatedAt)
                        }
                        if let due = task.dueAt { section("截止时间", text: SavedTime.text(due)) }
                        if !reminders.isEmpty { section("提醒", text: reminders.map { AssistantDates.text($0.fireAt) }.joined(separator: "、")) }
                        if let scope = task.scope {
                            section("完成标准", text: scope.doneCriteria)
                            if let approach = task.plan?.brief.approach, !approach.isEmpty { section("当前打算", text: approach.joined(separator: "；")) }
                            DisclosureGroup("交办与结果位置") {
                                VStack(alignment: .leading, spacing: 12) {
                                    section("确认的目标", text: scope.goal)
                                    section("你交办的事", text: task.rawInput.isEmpty ? "处理所附资料" : task.rawInput)
                                    section("结果位置", text: scope.outputDirectory)
                                }.padding(.top, 10)
                            }.font(BloomTypography.font(12)).foregroundStyle(BloomTheme.muted)
                        } else {
                            section("你交办的事", text: task.rawInput.isEmpty ? "处理所附资料，具体要求待确认。" : task.rawInput)
                        }
                        if task.scope != nil {
                            AssistantExecutionDetailView(model: model, task: task, onCopy: onCopy)
                        }
                        if task.scope == nil && !model.materials.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                label("资料 \(model.materials.count)")
                                ForEach(model.materials) { material in
                                    HStack(spacing: 8) {
                                        BloomSymbol(material.kind == .file ? "doc.text" : material.kind == .chat ? "text.bubble" : "leaf", size: 14)
                                        Text(material.title).lineLimit(2)
                                        Spacer()
                                        Text(material.kind == .chat ? "尚未授权" : "尚未发送").font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
                                    }
                                }
                            }
                        }
                        if task.scope == nil && !model.events.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                label("进度")
                                ForEach(Array(model.events.prefix(allEvents ? model.events.count : 5))) { event in
                                    Text("· " + event.text).foregroundStyle(BloomTheme.muted)
                                }
                                if model.events.count > 5 { Button(allEvents ? "收起记录" : "展开全部") { allEvents.toggle() }.buttonStyle(.plain) }
                            }
                        }
                        if task.scope == nil, let summary = task.resultSummary { section("结果", text: summary) }
                        HStack {
                            if !task.status.isTerminal {
                                Button(task.scope == nil ? "取消任务" : "停止任务") { Task { if await model.cancel(taskID) { onBack() } } }.buttonStyle(BloomButtonStyle())
                            } else if task.status != .cancelled {
                                Button("删除任务") { deleting = true }.buttonStyle(BloomButtonStyle())
                            }
                            Spacer()
                        }
                    }.font(BloomTypography.font(13)).padding(.bottom, 44)
                }
            } else { Text("这件事已删除").foregroundStyle(BloomTheme.muted); Spacer() }
        }.padding(16).task(id: model.task(taskID)?.updatedAt) {
            await model.loadDetail(taskID)
            reminders = ((try? await model.coordinator.pendingReminders()) ?? []).filter { $0.taskID == taskID && $0.state == "pending" }
        }
            .confirmationDialog("删除任务记录？", isPresented: $deleting) {
                Button("删除任务", role: .destructive) { Task { if await model.delete(taskID) { onBack() } } }
            } message: { Text("只移除任务记录，结果文件仍保留在原文件夹。") }
    }
    private func label(_ title: String) -> some View { Text(title).font(BloomTypography.font(12, role: .label)) }
    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { label(title); Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
    }
}

struct ComposerAttachmentRow: View {
    let attachments: [AssistantAttachment]
    let onRemove: (String) -> Void
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if expanded {
                ScrollView {
                    VStack(spacing: 6) { rows }
                }.frame(height: CGFloat(max(0, min(attachments.count, 5) * 36 - 6)))
            } else { rows }
            if attachments.count > 3 {
                Button(expanded ? "收起附件" : "+\(attachments.count - 3)") { expanded.toggle() }
                    .font(BloomTypography.font(11, role: .label)).foregroundStyle(BloomTheme.blue)
                    .buttonStyle(.plain).frame(minHeight: 22)
            }
        }
    }
    private var rows: some View {
        ForEach(Array(attachments.prefix(expanded ? attachments.count : 3))) { item in
            HStack(spacing: 8) {
                BloomSymbol(item.kind == .file ? "doc.text" : "leaf", size: 12)
                Text(item.title).lineLimit(1)
                Spacer()
                BloomIconButton(title: "移除附件：\(item.title)", symbol: "x", size: 22) { onRemove(item.id) }
            }.font(BloomTypography.font(11)).padding(.leading, 10).padding(.trailing, 4)
                .frame(height: 30).modifier(BloomSurface(color: BloomTheme.well, radius: 15))
        }
    }
}
