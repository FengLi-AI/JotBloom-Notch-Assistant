import AppKit
import ImageIO
import JotBloomCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum AssistantExternalActions {
    static func reveal(_ url: URL, handoff: (() -> Void)?) async throws {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { throw ExecutionError.unreadable("文件已移动或不存在，无法在访达定位。") }
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else { throw ExecutionError.unreadable("暂时无法打开访达。") }
        let config = NSWorkspace.OpenConfiguration(); config.activates = false
        let app = try await NSWorkspace.shared.openApplication(at: finder, configuration: config)
        handoff?()
        NSWorkspace.shared.activateFileViewerSelecting([url])
        app.activate(options: [.activateIgnoringOtherApps])
    }
    static func open(_ url: URL, handoff: (() -> Void)?) throws {
        guard NSWorkspace.shared.open(url) else { throw ExecutionError.unreadable("没有找到可打开此项目的应用。") }
        handoff?()
    }
}

struct AssistantSupervisionView: View {
    @ObservedObject var model: AssistantViewModel
    let session: AgentSession
    let completed: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield").foregroundStyle(BloomTheme.blue)
                Text("萌生监督").font(BloomTypography.font(12, role: .label))
                Spacer(minLength: 8)
                if let date = session.supervision?.reviewedAt {
                    Text(date, style: .time).font(BloomTypography.font(10)).foregroundStyle(BloomTheme.muted)
                }
            }
            Text(completed ? "已核对本次交付，结果见下方。" : session.supervision?.summary ?? "正在推进；此前版本未保留过程监督结论。")
                .font(BloomTypography.font(12)).fixedSize(horizontal: false, vertical: true)
            if let count = session.supervision?.corrections, count > 0 {
                Text("本轮已提醒纠偏 \(count) 次").font(BloomTypography.font(10)).foregroundStyle(BloomTheme.muted)
            }
            if let thread = session.threadID, let url = AgentThreadLink.url(thread) {
                Button("在 Codex 中打开") {
                    do { try AssistantExternalActions.open(url, handoff: model.onExternalHandoff) }
                    catch { model.feedback = error.localizedDescription }
                }.buttonStyle(BloomButtonStyle())
                Text("打开对应会话；能否实时跟随取决于 Codex 客户端。")
                    .font(BloomTypography.font(10)).foregroundStyle(BloomTheme.muted)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).modifier(BloomSurface(color: BloomTheme.well, radius: 12))
    }
}

struct AssistantResultImageView: View {
    @ObservedObject var model: AssistantViewModel
    let taskID: String
    let file: AssistantResultFile
    let revision: Int64
    @State private var image: NSImage?
    @State private var failure: String?
    @State private var showing = false
    @State private var protectingFocus = false
    var body: some View {
        Group {
            if let image {
                Button { protectingFocus = true; model.onSystemInteraction?(true); showing = true } label: {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 150)
                        .padding(6).background(BloomTheme.surface.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).help("放大预览 " + file.name).accessibilityLabel("预览 " + file.name)
            } else if let failure { Text(failure).font(BloomTypography.font(10)).foregroundStyle(BloomTheme.muted) }
            else { HStack { ProgressView().controlSize(.small); Text("载入图片…").font(BloomTypography.font(10)) }.frame(height: 70) }
        }
        .task(id: "\(file.name):\(file.bytes):\(revision)") {
            do {
                let data = try await model.coordinator.readExecutionImage(taskID, name: file.name)
                let preview = try await Task.detached(priority: .utility) { try Self.thumbnail(data) }.value
                try Task.checkCancellation()
                guard let loaded = NSImage(data: preview) else { throw ExecutionError.unreadable("暂时无法解码图片，可使用“打开文件”。") }
                image = loaded; failure = nil
            } catch { if !Task.isCancelled { image = nil; failure = error.localizedDescription } }
        }
        .sheet(isPresented: $showing, onDismiss: releaseFocus) {
            VStack(spacing: 16) {
                HStack { Text(file.name).font(BloomTypography.font(14, role: .label)).lineLimit(2); Spacer(); Button("关闭") { showing = false }.keyboardShortcut(.cancelAction) }
                if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.padding(20).frame(minWidth: 500, idealWidth: 760, maxWidth: 1000, minHeight: 360, idealHeight: 560, maxHeight: 800)
        }
        .onDisappear { releaseFocus() }
    }
    private func releaseFocus() {
        guard protectingFocus else { return }
        protectingFocus = false; model.onSystemInteraction?(false)
    }
    private static func thumbnail(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1800, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ExecutionError.unreadable("图片无法预览，可使用“打开文件”检查。") }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else { throw ExecutionError.unreadable("图片预览暂不可用。") }
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExecutionError.unreadable("图片预览未能生成。") }
        return result as Data
    }
}
