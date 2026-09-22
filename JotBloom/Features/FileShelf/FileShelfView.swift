import AppKit
import JotBloomCore
import SwiftUI

struct FileShelfView: View {
    @ObservedObject var model: FileShelfViewModel
    @ObservedObject var drag: FileShelfDragController
    @Environment(\.bloomExpanded) private var expanded
    @State private var selecting = false
    private var kinds: [ShelfFileKind?] { [nil] + ShelfFileKind.allCases.map(Optional.some) }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("中转站").font(BloomTypography.font(13, role: .label))
                if drag.hovering { Text("松手加入").font(BloomTypography.font(10)).foregroundStyle(BloomTheme.blue) }
                Spacer(minLength: 0)
                timeMenu
                Button(selecting ? "完成" : "批量选择") { selecting.toggle(); if !selecting { model.selection = [] } }
                    .buttonStyle(.plain).font(BloomTypography.font(11)).foregroundStyle(BloomTheme.blue)
                Menu {
                    Button("添加本地文件…") { chooseFile(replacing: nil) }
                    Button("刷新原文件状态") { Task { await model.refresh() } }
                    Divider()
                    Button("清空中转站…", role: .destructive) { model.confirmingClear = true }.disabled(model.items.isEmpty)
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("中转站操作").accessibilityLabel("中转站操作")
            }.frame(height: 24)
            BloomAdaptiveLibrary(kind: .files, expanded: expanded, sidebar: {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(kinds, id: \.self) { kind in
                            BloomLibrarySidebarButton(title: kind?.title ?? "全部", symbol: kind?.symbol ?? "square.grid.2x2", active: model.kind == kind) { model.kind = kind }
                        }
                    }
                }.scrollIndicators(.hidden)
            }, filters: {
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(kinds, id: \.self) { kind in
                            BloomLibraryFilter(title: kind?.title ?? "全部", active: model.kind == kind) { model.kind = kind }
                        }
                    }
                }.scrollIndicators(.hidden)
            }) { layout in
                    FileShelfGrid(model: model, drag: drag, metrics: layout, batchSelection: selecting, onChooseReplacement: { chooseFile(replacing: $0) })
                        .overlay {
                            if model.visibleItems.isEmpty {
                                VStack(spacing: 6) {
                                    Image(systemName: "folder.badge.plus").font(.system(size: 25, weight: .light))
                                    Text(model.ready ? (model.items.isEmpty ? "拖入文件，稍后从这里拖出使用" : "没有符合条件的文件") : "正在读取中转站…")
                                        .font(BloomTypography.font(11))
                                    if !model.items.isEmpty { Text("可切换类型或重置时间筛选").font(BloomTypography.font(10)) }
                                }.foregroundStyle(BloomTheme.muted).allowsHitTesting(false)
                            }
                        }
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(drag.hovering ? BloomTheme.blue.opacity(0.45) : .clear, style: StrokeStyle(lineWidth: 1, dash: [4, 4])).allowsHitTesting(false) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 8) {
                if selecting || !model.selection.isEmpty {
                    Text("已选 \(model.selection.count) 项").font(BloomTypography.font(10))
                    Button("全选") { model.selectAll() }.buttonStyle(.plain)
                    Button("移除") { Task { await model.removeSelection() } }.buttonStyle(.plain).disabled(model.selection.isEmpty)
                    if let feedback = model.feedback { Text(feedback).lineLimit(1).help(feedback) }
                } else {
                    Text(model.feedback ?? "\(model.visibleItems.count) 项 · 只存引用，原文件不变")
                        .lineLimit(1).help(model.feedback ?? "拖动排序；拖出使用；右键可定位原文件或调整顺序")
                }
                if model.canUndo { Button("撤销") { Task { await model.undo() } }.buttonStyle(.plain).foregroundStyle(BloomTheme.blue) }
                Spacer(minLength: 0)
                if model.busy { ProgressView().controlSize(.mini) }
            }.font(BloomTypography.font(10)).foregroundStyle(BloomTheme.muted)
                .frame(height: 24).padding(.trailing, 32)
        }.padding(.horizontal, 12).padding(.vertical, 8)
            .disabled(model.busy || model.confirmingClear)
            .accessibilityHidden(model.confirmingClear)
            .overlay {
                if model.confirmingClear {
                    ZStack {
                        Color.black.opacity(0.35).contentShape(Rectangle()).onTapGesture { }
                        VStack(alignment: .leading, spacing: 16) {
                            Text("清空中转站的 \(model.items.count) 项？").font(BloomTypography.font(16, role: .label))
                            Text("将移除所有类型和日期下的引用，不会删除原文件。").font(BloomTypography.font(12))
                            HStack {
                                Spacer()
                                Button("取消") { model.confirmingClear = false }.keyboardShortcut(.cancelAction).buttonStyle(BloomButtonStyle())
                                Button("确认清空") { Task { await model.clearConfirmed() } }.keyboardShortcut(.defaultAction).buttonStyle(BloomButtonStyle(primary: true))
                            }.disabled(model.busy)
                        }.padding(20).frame(width: 330).modifier(BloomSurface(color: BloomTheme.well, radius: 16))
                    }
                }
            }
            .task { if !model.ready { await model.load() }; if !drag.active { await model.refresh() } }
    }
    private var timeTitle: String {
        switch model.date {
        case .all: return "时间"
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .month(let day): return day.formatted(.dateTime.year().month())
        case .day(let day): return day.formatted(.dateTime.month().day())
        }
    }
    private var months: [Date] { Array(Set(model.items.compactMap { Calendar.current.dateInterval(of: .month, for: $0.addedAt)?.start })).sorted(by: >) }
    private var timeMenu: some View {
        Menu {
            Button("全部时间") { model.date = .all }
            Button("今天") { model.date = .today }
            Button("昨天") { model.date = .yesterday }
            ForEach(months, id: \.self) { month in
                Menu(month.formatted(.dateTime.year().month())) {
                    Button("整月") { model.date = .month(month) }
                    let days = Array(Set(model.items.filter { Calendar.current.isDate($0.addedAt, equalTo: month, toGranularity: .month) }.map { Calendar.current.startOfDay(for: $0.addedAt) })).sorted(by: >)
                    ForEach(days, id: \.self) { day in
                        Button(day.formatted(.dateTime.month().day())) { model.date = .day(day) }
                    }
                }
            }
            Divider()
            Button("重置所有筛选") { model.resetFilters() }
        } label: {
            Label(timeTitle, systemImage: "calendar").font(BloomTypography.font(10))
                .foregroundStyle(model.date == .all ? BloomTheme.muted : BloomTheme.blue)
                .padding(.horizontal, 6).frame(height: 24)
        }.menuStyle(.borderlessButton).fixedSize().help("按加入时间筛选；可与类型组合").accessibilityLabel("按时间筛选：\(timeTitle)")
    }
    private func chooseFile(replacing id: UUID?) {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = true; picker.allowsMultipleSelection = id == nil
        picker.prompt = id == nil ? "加入中转站" : "关联原文件"
        drag.onActivity(true)
        picker.begin { response in
            drag.onActivity(false)
            guard response == .OK else { return }
            Task { @MainActor in
                if let id, let url = picker.urls.first { await model.replace(id, with: url) }
                else { model.resetFilters(); _ = await model.add(picker.urls) }
            }
        }
    }
}
