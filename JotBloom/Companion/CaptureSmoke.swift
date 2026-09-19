#if DEBUG
import AppKit
import JotBloomCore

@MainActor
enum CaptureSmoke {
    static func run(controller: CompanionController, context: ApplicationExtensionContext, directory: URL) async throws -> [[String: Any]] {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        guard let capture = controller.capture, let notch = controller.overlay?.notch else { return [["name": "native capture is connected", "passed": false]] }
        let data = try DataLocationStore(controlDirectory: URL(fileURLWithPath: ProcessInfo.processInfo.environment["JOTBLOOM_DEBUG_DATA_DIRECTORY"]!)).activeDirectory()
        let storage = try JotBloomStore(dataDirectoryURL: data)
        defer { storage.close() }
        try storage.persistDraftSynchronously(kind: .inspiration, content: "输入框中未完成的草稿", updatedAtUTCms: 1)
        controller.resident = true
        controller.captureEnabled = true
        context.hidePanel()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        check("physical notch capture is enabled only with panel closed", capture.canReceive)
        let hotZone = HotZoneWindowController(onActivate: {})
        hotZone.start()
        defer { hotZone.stop() }
        check("host installs a real drag destination", NSApp.windows.contains { $0.contentView is NotchDropView })
        check("drop window is exactly the physical notch, never the lower hint", hotZone.debugWindowFrames.contains { $0 == notch })
        check("feedback is wholly input-transparent", capture.feedback.ignoresMouseEvents)
        let text = "捕捉一闪而过的想法\n先留下原文，再慢慢整理。🌱"
        capture.hover(); capture.advance(0.35)
        check("drag hover shows release hint", capture.phase == .hover && capture.feedback.stage.label == "松手即可收录灵感")
        capture.leave(); capture.advance(0.3)
        check("leaving without dropping does not save", try capture.phase == .idle && storage.listRecentInspirationsSynchronously().isEmpty)
        check("real external write is accepted", capture.accept(text, sequence: 1001))
        check("release changes copy immediately", capture.phase == .ack && capture.feedback.stage.label == "收到，正在收录")
        _ = capture.accept(text, sequence: 1001)
        for _ in 0..<30 where capture.pending > 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        check("accepted text exists once in the app database", try storage.listRecentInspirationsSynchronously().filter { $0.body == text }.count == 1)
        check("external write preserved the unfinished draft", try storage.loadDraftSynchronously(kind: .inspiration)?.content == "输入框中未完成的草稿")
        capture.advance(0.6)
        check("confirmed disk write proceeds to absorption", capture.phase == .absorb)
        capture.advance(0.83); check("absorption proceeds to physical rim", capture.phase == .glow)
        capture.advance(0.93); capture.advance(0.33)
        let received = controller.engine?.frame(dt: 0, preset: controller.preset)
        check("native receipt reaches resident engine without an entrance", received?.text("event") == "receive" && received?.text("phase") == "active" && received?.number("opacity") == 1)

        var succeeded = 0
        let failing = NotchCaptureController(); failing.locate(notch); failing.canWrite = { true }
        failing.save = { _ in throw PersistenceError.databaseClosed }; failing.received = { succeeded += 1 }
        _ = failing.accept("无法写入", sequence: 2)
        try await Task.sleep(nanoseconds: 100_000_000); failing.advance(0.6)
        check("save failure cannot play success glow or receipt", failing.phase == .failure && succeeded == 0)
        failing.stop()

        let closed = NotchCaptureController(); closed.locate(notch); closed.canWrite = context.canSaveInspiration
        closed.save = { value in try await Task.sleep(nanoseconds: 100_000_000); try await context.saveInspiration(value) }
        closed.received = { succeeded += 1 }
        _ = closed.accept("点击收回不会撤销已经接住的灵感", sequence: 3); closed.dismiss()
        try await Task.sleep(nanoseconds: 250_000_000)
        check("dismiss suppresses receipt while preserving accepted storage write", try succeeded == 0 && storage.listRecentInspirationsSynchronously().contains { $0.body == "点击收回不会撤销已经接住的灵感" })
        closed.stop()
        context.showPanel(); check("opening the app disables the notch drop target", !capture.canReceive)
        context.hidePanel()

        // Render actual drawing code, including the exposed open rim, for review.
        let image = CGContext(data: nil, width: 960, height: 480, bitsPerComponent: 8, bytesPerRow: 960 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        image.setFillColor(CGColor(red: 0.07, green: 0.31, blue: 0.54, alpha: 1)); image.fill(CGRect(x: 0, y: 0, width: 960, height: 480))
        for (i, p) in [NotchFeedbackPhase.hover, .ack, .absorb, .glow].enumerated() {
            let view = NotchFeedbackView(frame: CGRect(x: 0, y: 0, width: 480, height: 144))
            view.phase = p; view.expansion = 1; view.elapsed = p == .absorb ? 0.4 : 0.3; view.label = p == .hover ? "松手即可收录灵感" : "收到，正在收录"
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let cell = CGRect(x: (i % 2) * 480, y: (1 - i / 2) * 240, width: 480, height: 144)
                image.draw(bitmap.cgImage!, in: cell)
            }
        }
        if let result = image.makeImage(), let png = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]) { try png.write(to: directory.appendingPathComponent("native-capture-feedback.png")) }
        return checks
    }
}
#endif
