import AppKit
import JavaScriptCore

struct CompanionFrame {
    let state: [String: Any]
    let commands: [[Any]]
    func number(_ key: String) -> CGFloat { (state[key] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0 }
    func flag(_ key: String) -> Bool { state[key] as? Bool ?? false }
    func text(_ key: String) -> String { state[key] as? String ?? "" }
}

enum CompanionEngineError: Error { case missingResource(String), javaScript(String) }

@MainActor
final class NativeCompanionEngine {
    private let context: JSContext
    private let api: JSValue
    private(set) var lastError: String?

    init(resident: Bool, backdrop: Bool, frequency: Double, reduced: Bool) throws {
        guard let context = JSContext() else { throw CompanionEngineError.javaScript("无法创建动画环境") }
        self.context = context
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        for resource in ["companion-engine", "native-renderer"] {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "js") else {
                throw CompanionEngineError.missingResource(resource)
            }
            context.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: url)
        }
        if let failure { throw CompanionEngineError.javaScript(failure) }
        guard let api = context.objectForKeyedSubscript("NativeCompanion"), !api.isUndefined else {
            throw CompanionEngineError.javaScript("动画资源未加载")
        }
        self.api = api
        api.invokeMethod("init", withArguments: [["resident": resident, "backdrop": backdrop,
                                                "frequency": frequency, "reduced": reduced]])
        if let failure { throw CompanionEngineError.javaScript(failure) }
        context.exceptionHandler = { [weak self] _, exception in self?.lastError = exception?.toString() }
    }

    @discardableResult
    func action(_ name: String, _ value: Any = false) -> Bool {
        api.invokeMethod("action", withArguments: [name, value])?.toBool() ?? false
    }

    func frame(dt: Double, preset: String, gaze: CGPoint = .zero) -> CompanionFrame? {
        guard let result = api.invokeMethod("frame", withArguments: [dt, preset, gaze.x, gaze.y])?.toDictionary(),
              let state = result["state"] as? [String: Any],
              let commands = result["commands"] as? [[Any]] else { return nil }
        return CompanionFrame(state: state, commands: commands)
    }

    func thumbnail(_ preset: String, mood: String = "idle") -> CGImage? {
        guard let commands = api.invokeMethod("thumbnail", withArguments: [preset, mood])?.toArray() as? [[Any]] else { return nil }
        return CompanionRasterizer.render(commands)
    }
}

enum CompanionRasterizer {
    private static var colors: [String: CGColor] = [:]

    static func render(_ commands: [[Any]]) -> CGImage? {
        guard let context = CGContext(data: nil, width: 80, height: 64, bitsPerComponent: 8, bytesPerRow: 80 * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .none
        for command in commands {
            guard let op = command.first as? String else { continue }
            func n(_ i: Int) -> CGFloat { (command[i] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0 }
            switch op {
            case "save": context.saveGState()
            case "restore": context.restoreGState()
            case "transform":
                context.concatenate(context.ctm.inverted())
                context.translateBy(x: 0, y: 64)
                context.scaleBy(x: 1, y: -1)
                context.concatenate(CGAffineTransform(a: n(1), b: n(2), c: n(3), d: n(4), tx: n(5), ty: n(6)))
            case "translate": context.translateBy(x: n(1), y: n(2))
            case "scale": context.scaleBy(x: n(1), y: n(2))
            case "rotate": context.rotate(by: n(1))
            case "begin": context.beginPath()
            case "rect": context.addRect(CGRect(x: n(1), y: n(2), width: n(3), height: n(4)))
            case "fillRect": context.fill(CGRect(x: n(1), y: n(2), width: n(3), height: n(4)))
            case "fill": context.fillPath()
            case "clip": context.clip()
            case "alpha": context.setAlpha(n(1))
            case "color":
                if let hex = command[1] as? String { context.setFillColor(color(hex)) }
            default: break
            }
        }
        return context.makeImage()
    }

    private static func color(_ hex: String) -> CGColor {
        if let cached = colors[hex] { return cached }
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        let result = CGColor(red: CGFloat((value >> 16) & 255) / 255,
                             green: CGFloat((value >> 8) & 255) / 255,
                             blue: CGFloat(value & 255) / 255, alpha: 1)
        colors[hex] = result
        return result
    }
}
