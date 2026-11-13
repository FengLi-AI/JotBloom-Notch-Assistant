import AppKit
import JotBloomCore
import SwiftUI

/// Shared by the conversation and task detail; state belongs to the saved task.
struct AssistantTaskActionView: View {
    @ObservedObject var model: AssistantViewModel
    let task: AssistantTask
    var onSettings: () -> Void = {}
    @State private var answers: [String: String] = [:]
    @State private var rewrite = ""
    @State private var rewriting = false
    @State private var pending: [AssistantReminder] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if task.status == .needsInfo, let brief = task.brief {
                Text("确认 \(brief.questions.count) 件事").font(BloomTypography.font(14, role: .label))
                ForEach(brief.questions) { question in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(question.text)
                        if question.kind != "text" {
                            ViewThatFits(in: .horizontal) {
                                HStack { options(question) }
                                VStack(alignment: .leading, spacing: 6) { options(question) }
                            }
                        }
                        HStack {
                            TextField("补充你的想法", text: Binding(get: { answers[question.id] == "你来定" ? "" : answers[question.id, default: ""] }, set: { answers[question.id] = $0 })).textFieldStyle(.roundedBorder)
                            choice("你来定", question: question)
                        }
                    }
                }
                HStack { Spacer(); Button("继续") { model.coordinator.retry(task.id, answers: answers) }
                    .buttonStyle(BloomButtonStyle(primary: true))
                    .disabled(!brief.questions.allSatisfy { !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) }
            } else if task.status == .planReady, let plan = task.plan {
                AssistantPlanCard(model: model, taskID: task.id, initial: plan)
            } else if task.status == .scheduled {
                Text("✓ 已设好：" + (task.plan?.reminders.map(AssistantDates.text).joined(separator: "、") ?? "提醒"))
                    .foregroundStyle(BloomTheme.blue)
                Text("助手只在萌生运行时工作。退出或关机后不会提醒。")
                    .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
                if !pending.isEmpty {
                    Text("提醒待处理：\(pending.count) 条")
                    HStack {
                        Button("晚点再说") { resolve(snooze: true) }.buttonStyle(BloomButtonStyle())
                        Button("知道了") { resolve(snooze: false) }.buttonStyle(BloomButtonStyle(primary: true))
                    }
                }
                Button("撤销提醒") { Task { _ = await model.cancel(task.id) } }.buttonStyle(.plain).foregroundStyle(BloomTheme.blue)
            } else if task.scope != nil && [.queued, .running, .waitingUser, .interrupted, .failed].contains(task.status) {
                AssistantExecutionActionView(model: model, task: task)
            } else if task.errorCode == "modelNotConfigured" {
                Text("先配置模型，助手才能理解任务。交办内容已保存。")
                HStack {
                    Button("去设置", action: onSettings).buttonStyle(BloomButtonStyle(primary: true))
                    Button("已配置，继续") { model.coordinator.retry(task.id) }.buttonStyle(BloomButtonStyle())
                }
            } else if task.errorCode == "understandingInvalid" || (task.status == .interrupted && task.scope == nil) {
                Text("没能理解，交办内容仍保留。")
                HStack {
                    Button("重试") { model.coordinator.retry(task.id) }.buttonStyle(BloomButtonStyle(primary: true))
                    Button("改写") { rewriting.toggle() }.buttonStyle(BloomButtonStyle())
                }
                if rewriting {
                    TextField("补充或改写要求", text: $rewrite).textFieldStyle(.roundedBorder)
                    Button("重新理解") { model.coordinator.retry(task.id, adjustment: rewrite) }.disabled(rewrite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if task.status == .understanding {
                HStack { ProgressView().controlSize(.small); Text("正在理解…你可以继续聊天。") }
            }
        }.font(BloomTypography.font(13)).frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).modifier(BloomSurface(color: BloomTheme.well, radius: 16))
            .task(id: "\(task.updatedAt)-\(model.coordinator.deliveredReminders.map(\.id).joined())") { pending = ((try? await model.coordinator.pendingReminders()) ?? []).filter { $0.taskID == task.id && $0.state != "pending" } }
    }
    @ViewBuilder private func options(_ question: TaskQuestion) -> some View {
        ForEach(question.options, id: \.self) { choice($0, question: question) }
    }
    private func choice(_ title: String, question: TaskQuestion) -> some View {
        let chosen = (answers[question.id] ?? "").components(separatedBy: "、").contains(title)
        return Button(title) {
            if question.kind == "multi", title != "你来定" {
                var values = Set((answers[question.id] ?? "").components(separatedBy: "、").filter { !$0.isEmpty && $0 != "你来定" })
                if !values.insert(title).inserted { values.remove(title) }
                answers[question.id] = values.sorted().joined(separator: "、")
            } else { answers[question.id] = title }
        }.buttonStyle(AssistantChoiceStyle(selected: chosen))
    }
    private func resolve(snooze: Bool) {
        Task {
            do { try await model.coordinator.resolveReminders(pending.map(\.id), snooze: snooze); pending = [] }
            catch { model.feedback = error.localizedDescription }
        }
    }
}

struct AssistantPlanCard: View {
    @ObservedObject var model: AssistantViewModel
    let taskID: String
    @State private var plan: AssistantPlan
    @State private var adjusting = false
    @State private var adjustment = ""
    @State private var adding = false
    @State private var candidates: [AssistantAttachment] = []
    @State private var saving = false
    init(model: AssistantViewModel, taskID: String, initial: AssistantPlan) {
        self.model = model; self.taskID = taskID
        var initial = initial; initial.restrictCodex(to: model.coordinator.agentAvailability)
        _plan = State(initialValue: initial)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(plan.brief.title).font(BloomTypography.font(16, role: .label))
            VStack(alignment: .leading, spacing: 6) {
                label("我的理解")
                TextField("目标", text: $plan.brief.summary, axis: .vertical).textFieldStyle(.plain)
                label("做到什么算完成")
                TextField("完成标准", text: $plan.brief.doneCriteria, axis: .vertical).textFieldStyle(.plain)
            }
            if !plan.brief.assumptions.isEmpty { Text("默认：" + plan.brief.assumptions.joined(separator: "；")).foregroundStyle(BloomTheme.muted).font(BloomTypography.font(11)) }
            VStack(alignment: .leading, spacing: 8) {
                Toggle("截止时间", isOn: Binding(get: { plan.dueAt != nil }, set: { resetReminders(due: $0 ? ms(Date().addingTimeInterval(86400)) : nil) }))
                if plan.dueAt != nil {
                    DatePicker("截止", selection: Binding(get: { date(plan.dueAt!) }, set: { resetReminders(due: ms($0)) }), displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                    Text(AssistantDates.text(plan.dueAt!)).font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
                }
                ForEach(Array(plan.reminders.indices), id: \.self) { index in
                    HStack {
                        DatePicker("提醒", selection: Binding(get: { date(plan.reminders[index]) }, set: { plan.editReminder(at: index, time: ms($0)) }), displayedComponents: [.date, .hourAndMinute])
                        if plan.reminderIsAfterDeadline(plan.reminders[index]) { Text("在截止之后").font(BloomTypography.font(10)).foregroundStyle(BloomTheme.muted) }
                        Button("移除") { plan.removeReminder(at: index) }.buttonStyle(.plain).foregroundStyle(BloomTheme.muted)
                    }
                }
                Button("＋ 添加提醒") { plan.addReminder(ms(Date().addingTimeInterval(3600)), origin: .user) }.buttonStyle(.plain).foregroundStyle(BloomTheme.blue)
                Text("只在萌生运行时提醒；已经过去的时间不会创建。")
                    .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
            }
            if !plan.brief.approach.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    label("打算这样做（中途可以调整）")
                    ForEach(Array(plan.brief.approach.enumerated()), id: \.offset) { index, text in Text("\(index + 1). \(text)").foregroundStyle(BloomTheme.muted) }
                }
            }
            Divider().opacity(0.3)
            VStack(alignment: .leading, spacing: 8) {
                label("你允许使用的资料")
                ForEach($plan.materials) { $material in
                    Toggle(isOn: $material.selected) {
                        Text(material.attachment.title + (material.available ? "" : " · 已失效"))
                            .lineLimit(2).foregroundStyle(material.available ? BloomTheme.text : BloomTheme.muted)
                    }.disabled(!material.available)
                }
                Button("＋ 添加资料") {
                    Task { candidates = (try? await model.coordinator.availableMaterials()) ?? []; adding.toggle() }
                }.buttonStyle(.plain).foregroundStyle(BloomTheme.blue)
                if adding {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(candidates.filter { item in !plan.materials.contains(where: { $0.id == item.id }) }) { item in
                                Button(item.title) { plan.materials.append(.init(item, selected: true)) }.buttonStyle(.plain)
                            }
                        }
                    }.frame(maxHeight: 140)
                    Button("选择本地文件…") { chooseFiles() }.buttonStyle(BloomButtonStyle())
                }
                Toggle("自动找相关资料", isOn: $plan.autoFind)
                Toggle("可以交给 Codex", isOn: Binding(get: { model.coordinator.agentAvailability.ready && plan.allowCodex }, set: { plan.allowCodex = model.coordinator.agentAvailability.ready && $0 }))
                    .disabled(!model.coordinator.agentAvailability.ready)
                Text(model.coordinator.agentAvailability.message)
                    .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
                if plan.allowCodex {
                    folderRow("工作文件夹", path: plan.workingDirectory ?? "未选择") { chooseFolder(working: true) }
                    if plan.workingDirectory != nil { Button("移除工作文件夹") { plan.workingDirectory = nil }.buttonStyle(.plain).foregroundStyle(BloomTheme.muted) }
                    Text("发送给 Codex：确认的目标、完成标准、补充要求和允许的资料。Codex 可能读取其他本机文件；联网后访问的网站不限于提供的链接。")
                        .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
                }
                folderRow("结果放在", path: plan.outputDirectory) { chooseFolder(working: false) }
                Toggle("允许联网查资料", isOn: $plan.allowNetwork)
                Text("点“开始”后，勾选资料才可发送给模型；未勾选的聊天原文不会用于执行。")
                    .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
            }
            if adjusting {
                TextField("用一句话说明要改什么", text: $adjustment).textFieldStyle(.roundedBorder)
                Button("重新生成计划") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            try await model.coordinator.savePlanDraft(id: taskID, plan: plan)
                            model.coordinator.retry(taskID, adjustment: adjustment)
                        } catch { model.feedback = "计划修改尚未保存，请重试。" }
                    }
                }
                    .buttonStyle(BloomButtonStyle()).disabled(adjustment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 8) {
                Button("取消") { Task { _ = await model.cancel(taskID) } }.buttonStyle(BloomButtonStyle())
                Button("调整") { adjusting.toggle() }.buttonStyle(BloomButtonStyle())
                Spacer(minLength: 8)
                Button(saving ? "保存中…" : "开始") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await model.coordinator.confirm(id: taskID, plan: plan) }
                        catch { model.feedback = error.localizedDescription }
                    }
                }.buttonStyle(BloomButtonStyle(primary: true)).disabled(saving || (plan.allowCodex && !model.coordinator.agentAvailability.ready) || plan.brief.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.top, 2)
        }.font(BloomTypography.font(12)).disabled(saving)
            .onChange(of: model.coordinator.agentAvailability) { value in plan.restrictCodex(to: value) }
            .onChange(of: plan) { value in
                Task { do { try await model.coordinator.savePlanDraft(id: taskID, plan: value) } catch { model.feedback = "计划修改尚未保存，请重试。" } }
            }
    }
    private func label(_ value: String) -> some View { Text(value).font(BloomTypography.font(12, role: .label)) }
    private func date(_ value: Int64) -> Date { Date(timeIntervalSince1970: Double(value) / 1000) }
    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
    private func resetReminders(due: Int64?) {
        let settings = model.coordinator.agentSettings
        plan.reschedule(due: due, now: ms(Date()), timeZone: .current,
            dayBeforeMinute: settings.reminderDayBefore, sameDayMinute: settings.reminderSameDay)
    }
    private func folderRow(_ title: String, path: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Text(title); Text(path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                .lineLimit(2).truncationMode(.middle).foregroundStyle(BloomTheme.muted)
            Spacer(minLength: 4); Button("选择", action: action).buttonStyle(.plain).foregroundStyle(BloomTheme.blue)
        }
    }
    private func chooseFolder(working: Bool) {
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.canCreateDirectories = true; picker.prompt = "选择文件夹"
        model.onSystemInteraction?(true)
        picker.begin { response in
            defer { model.onSystemInteraction?(false) }
            guard response == .OK, let url = picker.url else { return }
            if working { do { plan.workingDirectory = try AssistantFolders.validateWorking(url.path) } catch { model.feedback = error.localizedDescription } } else { plan.outputDirectory = url.appendingPathComponent(URL(fileURLWithPath: plan.outputDirectory).lastPathComponent).path }
        }
    }
    private func chooseFiles() {
        let picker = NSOpenPanel(); picker.allowsMultipleSelection = true; picker.canChooseDirectories = false
        model.onSystemInteraction?(true)
        picker.begin { response in
            defer { model.onSystemInteraction?(false) }
            guard response == .OK else { return }
            for url in picker.urls {
                let item = AssistantAttachment.file(url)
                if !plan.materials.contains(where: { $0.id == item.id }) { plan.materials.append(.init(item, selected: true)) }
            }
        }
    }
}

private struct AssistantChoiceStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(BloomTypography.font(12, role: .label))
            .padding(.horizontal, 12).frame(minHeight: 30)
            .foregroundStyle(selected ? Color.white : BloomTheme.text)
            .background(selected ? BloomTheme.blue : BloomTheme.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(selected ? 0.16 : 0.08), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
