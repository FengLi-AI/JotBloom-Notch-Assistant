import AppKit
import CoreText
import SwiftUI

enum BloomTypography {
    enum Role { case label, body }
    private static let faces: [String: CGFont] = {
        var result: [String: CGFont] = [:]
        for name in ["MiSans-Regular", "MiSans-Normal"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf"),
               let provider = CGDataProvider(url: url as CFURL), let font = CGFont(provider) { result[name] = font }
        }
        return result
    }()
    static var bundledFontsAvailable: Bool { faces.count == 2 }
    static func nsFont(_ size: CGFloat, role: Role = .body) -> NSFont {
        let name = role == .label ? "MiSans-Regular" : "MiSans-Normal"
        if let face = faces[name] { return CTFontCreateWithGraphicsFont(face, size, nil, nil) as NSFont }
        return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: role == .label ? .regular : .light)
    }
    static func font(_ size: CGFloat, role: Role = .body) -> Font { Font(nsFont(size, role: role)) }
}
