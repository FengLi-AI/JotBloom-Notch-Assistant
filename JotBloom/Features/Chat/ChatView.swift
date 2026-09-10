import AppKit
import JotBloomCore
import SwiftUI

private struct ChatFrames: PreferenceKey {
    static var defaultValue: [Int64: CGRect] = [:]
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
private final class ChatScrollReference: ObservableObject { weak var scroll: NSScrollView? }

struct ChatView: View {
    @ObservedObject var model: ChatViewModel
    @State private var viewportHeight: CGFloat = 0
    @State private var restoring = true
    @State private var pendingRestoration: (id: Int64, offset: Double)?
    @State private var lastFrames: [Int64: CGRect] = [:]
    @State private var copied: Int64?
    @State private var renaming: String?
    @State private var sessionName = ""
    @StateObject private var scrollReference = ChatScrollReference()
    var onCopy: (String) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AI 对话").font(.system(size: 17, weight: .semibold))
                if !model.showingHistory {
                    Text(model.sessions.first(where: \.isCurrent)?.title ?? "新对话")
                        .font(.system(size: 11)).foregroundStyle(BloomTheme.muted).lineLimit(1)
                }
                Spacer()
                Button(model.showingHistory ? "返回对话" : "历史对话") { model.toggleHistory() }
                    .disabled(!model.canManageSessions)
                Button("新对话") { model.requestNew() }.disabled(!model.canManageSessions)
                Button(model.summarizing ? "正在整理…" : "整理成灵感") { model.summarize() }.disabled(!model.canSummarize)
            }.buttonStyle(BloomButtonStyle()).frame(height: 32)
            if !model.configured {
                HStack {
                    Text("配置 AI 接口后可开始对话").font(.system(size: 12))
                    Button("前往 AI 设置") { model.onOpenSettings?() }.buttonStyle(.plain).foregroundStyle(BloomTheme.blue)
                }
            }
            if model.summaryPreview {
                summaryEditor
            } else if model.showingHistory {
                historyList
            } else {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if model.hasMore { Button(model.loadingMore ? "正在加载…" : "加载更早消息") { model.loadMore() }.disabled(model.loadingMore) }
                            if model.turns.isEmpty {
                                Text(model.ready ? "从一个模糊的想法开始。\nAI 帮你发散方向，再一起找到值得往下做的一步。" : "正在读取当前对话…")
                                    .foregroundStyle(BloomTheme.muted).padding(.vertical, 20)
                                if !model.ready { Button("重新读取") { Task { await model.start() } } }
                            }
                            ForEach(model.turns) { turn in
                                turnView(turn)
                                    .id(turn.id)
                                    .background(GeometryReader { frame in Color.clear.preference(key: ChatFrames.self, value: [turn.id: frame.frame(in: .named("chat-scroll"))]) })
                            }
                            Color.clear.frame(height: 1).id("bottom")
                                .background(GeometryReader { frame in Color.clear.preference(key: ChatFrames.self, value: [-1: frame.frame(in: .named("chat-scroll"))]) })
                        }.padding(.vertical, 6)
                        .background(ChatScrollMemory(model: model, onUserScroll: { nearBottom in
                            if model.followingLatest != nearBottom { model.followingLatest = nearBottom }
                        }, onAttach: { scrollReference.scroll = $0 }))
                    }
                    .coordinateSpace(name: "chat-scroll")
                    .onPreferenceChange(ChatFrames.self) { frames in
                        lastFrames = frames
#if DEBUG
                        model.debugVisibleOffsets = frames.mapValues { Double($0.minY) }
#endif
                        if let target = pendingRestoration, let frame = frames[target.id], let scroll = scrollReference.scroll {
                            let delta = frame.minY - target.offset
                            if abs(delta) > 0.5 {
                                scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY + delta))
                                scroll.reflectScrolledClipView(scroll.contentView)
                                return
                            }
                            pendingRestoration = nil; restoring = false
                        }
                        guard !restoring else { return }
                        if let first = frames.filter({ $0.key != -1 && $0.value.maxY > 0 }).min(by: { $0.value.minY < $1.value.minY }) {
                            model.scrollAnchor = first.key; model.scrollAnchorOffset = first.value.minY
                        }
                    }
                    .onAppear {
                        DispatchQueue.main.async {
                            if model.followingLatest { proxy.scrollTo("bottom", anchor: .bottom) }
                            else if model.scrollOffset == nil, let id = model.scrollAnchor { proxy.scrollTo(id, anchor: .top) }
                            DispatchQueue.main.async { restoring = false }
                        }
                    }
                    .onChange(of: model.turns.last?.answer) { _ in if model.followingLatest { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: model.turns.last?.id) { _ in if model.followingLatest { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: model.turns.first?.id) { _ in
                        guard let anchor = model.prependAnchor else { return }
                        model.prependAnchor = nil; restoring = true
                        DispatchQueue.main.async {
                            proxy.scrollTo(anchor.id, anchor: .top)
                            // Arm correction after ScrollViewReader has applied its own scroll.
                            // Otherwise an old matching frame can finish restoration prematurely.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                pendingRestoration = anchor
                                if let frame = lastFrames[anchor.id], let scroll = scrollReference.scroll {
                                    let delta = frame.minY - anchor.offset
                                    if abs(delta) > 0.5 {
                                        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY + delta))
                                        scroll.reflectScrolledClipView(scroll.contentView)
                                    } else {
                                        pendingRestoration = nil; restoring = false
                                    }
                                }
                            }
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !model.followingLatest, !model.turns.isEmpty {
                            Button("回到最新") { model.followingLatest = true; proxy.scrollTo("bottom", anchor: .bottom) }
                                .buttonStyle(BloomButtonStyle()).padding(4)
                        }
                    }
                }
            }
            .id(model.currentSession)
            }
            if let feedback = model.feedback {
                HStack {
                    Text(feedback).font(.system(size: 11)).foregroundStyle(BloomTheme.muted).lineLimit(2)
                    if model.needsStorageRetry { Button("重试保存") { model.retryStorage() }.disabled(model.busy) }
                    if model.needsCredentialHelp {
                        Button("前往 AI 设置") { model.onOpenSettings?() }
                            .buttonStyle(BloomButtonStyle()).disabled(model.busy)
                    }
                }
            }
            if model.summaryOversized {
                Button("仅整理最近 3 个完成轮次") { model.summarize(recentOnly: true) }.buttonStyle(BloomButtonStyle()).disabled(!model.canSummarize)
            }
            if !model.showingHistory && !model.summaryPreview {
            Text("消息及必要上下文会发送到设置的主模型，可能产生费用；未完成轮次不会加入后续上下文。")
                .font(.system(size: 10)).foregroundStyle(BloomTheme.muted).lineLimit(2)
            HStack(alignment: .bottom, spacing: 8) {
                ChatComposer(text: $model.draft, focusRequest: model.focusRequest, enabled: model.ready && !model.switching && !model.summarizing, onSend: model.send)
                    .frame(height: 60).modifier(BloomSurface(color: BloomTheme.well, radius: 14))
                if model.busy {
                    Button(model.authorizing ? "取消" : "停止") { model.stop() }.buttonStyle(BloomButtonStyle())
                } else {
                    Button("发送") { model.send() }.buttonStyle(BloomButtonStyle(primary: true)).disabled(!model.canSend)
                }
            }.padding(.trailing, 38)
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
        .foregroundStyle(BloomTheme.text)
        .onDisappear { model.confirmingDelete = false }
        .confirmationDialog("删除这条对话？", isPresented: $model.confirmingDelete) {
            Button("删除对话", role: .destructive) { model.deleteConversation() }
            Button("取消", role: .cancel) {}
        } message: { Text("“\(model.deletionTarget?.title ?? "此对话")”及其未发送草稿将被删除，不能恢复；其他对话、灵感库和提示词库不受影响。") }
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if model.sessions.isEmpty { Text("还没有历史对话。空白的新对话不会保存为记录。").foregroundStyle(BloomTheme.muted).padding(16) }
                ForEach(model.sessions) { session in
                    HStack(spacing: 10) {
                        if renaming == session.id {
                            TextField("对话名称（1–80 字）", text: $sessionName)
                                .textFieldStyle(.plain).onSubmit { saveName(session) }
                            Button("保存") { saveName(session) }
                                .disabled(sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sessionName.count > 80)
                            Button("取消") { renaming = nil }
                        } else {
                            Button { model.selectSession(session) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text(SavedTime.text(session.timestamp)).font(.system(size: 10)).foregroundStyle(BloomTheme.muted)
                                    }
                                    Spacer()
                                    if session.isCurrent { Text("当前").font(.system(size: 11)).foregroundStyle(BloomTheme.blue) }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            BloomIconButton(title: "重命名对话", symbol: "pencil") { sessionName = session.title; renaming = session.id }
                            BloomIconButton(title: "删除对话", symbol: "trash", destructive: true) { model.requestDelete(session) }
                                .padding(.leading, 8)
                        }
                    }.buttonStyle(BloomButtonStyle())
                        .padding(12).modifier(BloomSurface(color: session.isCurrent ? BloomTheme.selected : BloomTheme.well, radius: 18))
                        .disabled(!model.canManageSessions)
                }
            }.padding(.vertical, 6).padding(.bottom, 32)
        }
    }
    private var summaryEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("整理预览 · 确认后才保存").font(.system(size: 13, weight: .semibold))
            TextField("灵感标题", text: $model.summaryTitle).textFieldStyle(.plain).padding(12)
                .modifier(BloomSurface(color: BloomTheme.well)).accessibilityLabel("整理后的灵感标题")
            TextEditor(text: $model.summaryBody).font(.system(size: 14)).scrollContentBackground(.hidden)
                .padding(10).modifier(BloomSurface(color: BloomTheme.well)).accessibilityLabel("整理后的灵感正文")
            HStack {
                Spacer()
                Button("放弃预览") { model.discardSummary() }
                Button("保存灵感") { model.saveSummary() }.buttonStyle(BloomButtonStyle(primary: true))
            }.buttonStyle(BloomButtonStyle()).padding(.trailing, 38)
        }.disabled(model.busy)
    }
    private func saveName(_ session: ChatSession) {
        guard !sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, sessionName.count <= 80 else { return }
        let name = sessionName
        Task { if await model.renameSession(session, title: name) { renaming = nil } }
    }

    private func turnView(_ turn: ChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 40)
                Text(turn.user).font(.system(size: 13)).textSelection(.enabled)
                    .padding(10).modifier(BloomSurface(color: BloomTheme.selected, radius: 16))
            }
            HStack {
                Text(SavedTime.text(turn.timestamp)).font(.system(size: 10)).foregroundStyle(BloomTheme.muted)
                Spacer()
            }
            Text(turn.answer.isEmpty && turn.status.isActive ? "正在等待回复…" : turn.answer)
                .font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                if !turn.answer.isEmpty {
                    Button(copied == turn.id ? "已复制" : "复制回答") {
                        copied = onCopy(turn.answer) ? turn.id : nil
                    }.help("复制完整回答，不收起面板")
                }
                if !turn.status.isActive && turn.status != .complete {
                    Text(statusLabel(turn.status)).foregroundStyle(BloomTheme.muted)
                    if model.turns.last?.id == turn.id { Button("重试") { model.retry() }.disabled(!model.canRetry) }
                }
            }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(BloomTheme.blue)
        }
    }
    private func statusLabel(_ status: ChatStatus) -> String {
        switch status {
        case .stopped: return "已停止"
        case .interrupted: return "已中断"
        case .length: return "达到长度上限"
        default: return "回复未完成"
        }
    }
}
