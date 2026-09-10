import AppKit
import UniformTypeIdentifiers

// Inspect an extracted App without launching it or reading user data.
let args = CommandLine.arguments
guard args.count == 3 else { fatalError("Usage: swift verify-app-identity.swift APP_PATH NEW_PNG_PATH") }
let url = URL(fileURLWithPath: args[1])
let expected = "萌生｜JotBloom"
guard let bundle = Bundle(url: url) else { fatalError("Invalid bundle") }
precondition(url.lastPathComponent == expected + ".app")
precondition(bundle.bundleIdentifier == "com.jotbloom.mengsheng")
for key in ["CFBundleName", "CFBundleDisplayName"] {
    precondition(bundle.infoDictionary?[key] as? String == expected)
    precondition(bundle.object(forInfoDictionaryKey: key) as? String == expected)
}
precondition(bundle.infoDictionary?["CFBundleIconFile"] as? String == "AppIcon.icns")
let iconURL = url.appendingPathComponent("Contents/Resources/AppIcon.icns")
precondition(NSImage(contentsOf: iconURL) != nil)
let displayName = FileManager.default.displayName(atPath: url.path)
precondition(displayName == expected || displayName == expected + ".app")
let icon = NSWorkspace.shared.icon(forFile: url.path)
let generic = NSWorkspace.shared.icon(for: .applicationBundle)
precondition(icon.tiffRepresentation != generic.tiffRepresentation, "System returned generic application icon")
icon.size = NSSize(width: 256, height: 256)
guard let tiff = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot render system icon") }
precondition(!FileManager.default.fileExists(atPath: args[2]), "Refusing to overwrite output")
try png.write(to: URL(fileURLWithPath: args[2]))
print("PASS: copied-app name=\(displayName), custom system icon rendered, bundle ID unchanged; App not launched.")
