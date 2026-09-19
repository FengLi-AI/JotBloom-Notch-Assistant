#if DEBUG
import AppKit
import JotBloomCore

/// Runs only with an explicit output directory, against isolated preview data.
@MainActor
enum CompanionSmoke {
    static func run(controller: CompanionController, context: ApplicationExtensionContext, destination: String) async {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ result: Bool) { checks.append(["name": name, "passed": result]) }
        let directory = URL(fileURLWithPath: destination, isDirectory: true)
        do {
            controller.codexEnabled = false
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            check("companion module is attached to native settings", ApplicationExtensionHost.shared.module is JotBloomCompanionExtension)
            let engine = try NativeCompanionEngine(resident: false, backdrop: true, frequency: 50, reduced: false)
            func advance(_ duration: Double) -> CompanionFrame? {
                var result: CompanionFrame?
                for _ in 0..<Int(duration * 60) { result = engine.frame(dt: 1.0 / 60, preset: "chuichui") }
                return result
            }
            var images = Set<Data>()
            let moods = ["idle", "curious", "sleep", "energetic", "tired", "receive", "satisfied", "notify"]
            let sheet = CGContext(data: nil, width: 8 * 160, height: 6 * 128, bitsPerComponent: 8, bytesPerRow: 8 * 160 * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            sheet.setFillColor(CGColor(gray: 0.09, alpha: 1)); sheet.fill(CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
            sheet.interpolationQuality = .none
            for (row, character) in CompanionController.characters.enumerated() {
                for (column, mood) in moods.enumerated() {
                    if let image = engine.thumbnail(character.0, mood: mood), let bytes = image.dataProvider?.data {
                        let data = bytes as Data
                        let colored = stride(from: 3, to: data.count, by: 4).filter { data[$0] > 24 }.count
                        check("\(character.0)/\(mood) renders visible 80x64 pixels", image.width == 80 && image.height == 64 && colored > 100 && colored < 4000)
                        if mood == "idle" { images.insert(data) }
                        sheet.draw(image, in: CGRect(x: column * 160, y: (5 - row) * 128, width: 160, height: 128))
                    } else { check("\(character.0)/\(mood) renders", false) }
                }
            }
            check("six distinct characters", images.count == 6)
            if let image = sheet.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent("native-characters.png"))
            }
            engine.action("preview", "sleep")
            _ = advance(0.8)
            let entrance = engine.frame(dt: 0, preset: "chuichui")
            check("sleep enters already lying down", entrance?.text("kind") == "glide" && entrance?.text("mood") == "sleep" && entrance?.flag("restSettled") == true)
            let sleep = advance(2)
            check("occasional sleep lasts at least 30 seconds", sleep?.text("phase") == "active" && (sleep?.number("duration") ?? 0) >= 30)
            engine.action("interact")
            check("occasional click dismisses immediately", advance(0.3)?.text("phase") == "hidden")
            engine.action("resident", true)
            _ = advance(2)
            engine.action("interact")
            let touched = advance(0.3)
            check("resident click keeps it visible without a background", touched?.flag("backdrop") == false && (touched?.number("opacity") ?? 0) > 0.9 && touched?.text("phase") != "dismiss")
            engine.action("event", "receive")
            let receipt = advance(9)
            check("resident receipt returns to idle, not an exit", receipt?.text("phase") == "idle" && receipt?.number("opacity") == 1)
            engine.action("foreground", true)
            check("foreground suppresses a completion event", !engine.action("event", "notify"))
            check("bundled JavaScript completed without exceptions", engine.lastError == nil)

            controller.resident = true
            context.hidePanel()
            try await Task.sleep(nanoseconds: 600_000_000)
            check("real host hide callback returns the resident", !context.isPanelVisible() && controller.engine?.frame(dt: 0, preset: controller.preset)?.flag("appOpen") == false)
            context.showPanel()
            try await Task.sleep(nanoseconds: 500_000_000)
            check("real host show callback hides the companion", context.isPanelVisible() && controller.engine?.frame(dt: 0, preset: controller.preset)?.text("phase") == "hidden")
            context.hidePanel()
            try await Task.sleep(nanoseconds: 650_000_000)
            check("resident returns after the real panel closes", controller.engine?.frame(dt: 0, preset: controller.preset)?.text("phase") == "idle")
            if let overlay = controller.overlay, controller.hasNotch {
                check("native overlay ends at the physical notch", abs(overlay.frame.maxX - overlay.notch.minX) < 0.01 && abs(overlay.frame.height - overlay.notch.height) < 0.01)
                check("native companion window is actually visible", overlay.isVisible && !overlay.hidesOnDeactivate && overlay.stage.bounds.width > 0)
                check("transparent empty corner lets clicks through", !overlay.stage.containsVisiblePixel(CGPoint(x: 0, y: 0)))
                let visibleHit = (0..<Int(overlay.stage.bounds.width)).contains { x in
                    (0..<Int(overlay.stage.bounds.height)).contains { y in overlay.stage.containsVisiblePixel(CGPoint(x: x, y: y)) }
                }
                check("visible character pixels accept interaction", visibleHit)
                if let bitmap = overlay.stage.bitmapImageRepForCachingDisplay(in: overlay.stage.bounds) {
                    overlay.stage.cacheDisplay(in: overlay.stage.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("native-notch-stage.png"))
                }
            }
            controller.resident = false
            context.showPanel()
            try await Task.sleep(nanoseconds: 450_000_000)
            context.hidePanel()
            try await Task.sleep(nanoseconds: 450_000_000)
            check("occasional mode stays hidden after closing the app", controller.engine?.frame(dt: 0, preset: controller.preset)?.text("phase") == "hidden")
            let more = try await CaptureSmoke.run(controller: controller, context: context, directory: directory)
            checks.append(contentsOf: more)
        } catch { checks.append(["name": "native integration error", "passed": false, "error": String(describing: error)]) }
        let report: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true },
                                     "physicalNotchDetected": controller.hasNotch, "checks": checks]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("native-checks.json"))
        }
        NSApp.terminate(nil)
    }
}
#endif
