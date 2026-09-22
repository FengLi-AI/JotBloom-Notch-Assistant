import Foundation

/// Stable navigation identities; reserved features never become valid default routes.
public enum PanelSlot: String, Codable, CaseIterable {
    case inspiration, clipboard, prompts, inspirationLibrary, chat, fileShelf, globalSearch

    public static var navigationSlots: [Self] {
        [.inspiration, .inspirationLibrary, .clipboard, .prompts, .fileShelf, .chat]
    }

    public var isAvailable: Bool { true }
    public var title: String {
        switch self {
        case .inspiration: return "灵感"
        case .clipboard: return "剪贴板"
        case .prompts: return "提示词"
        case .inspirationLibrary: return "灵感库"
        case .chat: return "对话"
        case .fileShelf: return "中转站"
        case .globalSearch: return "搜索"
        }
    }
    public var symbol: String {
        switch self {
        case .inspiration: return "leaf"
        case .clipboard: return "doc.on.clipboard"
        case .prompts: return "text.badge.star"
        case .inspirationLibrary: return "square.stack.3d.up"
        case .chat: return "bubble.left.and.bubble.right"
        case .fileShelf: return "folder"
        case .globalSearch: return "magnifyingglass"
        }
    }
}

public enum PanelAppearance: String, CaseIterable {
    case dark, light
}

public struct PanelPreferences: Equatable {
    public private(set) var order: [PanelSlot]
    public var defaultSlot: PanelSlot {
        didSet { if !defaultSlot.isAvailable { defaultSlot = .inspiration } }
    }
    public var appearance: PanelAppearance
    public var reduceMotion: Bool

    public init(order: [PanelSlot] = PanelSlot.navigationSlots,
                defaultSlot: PanelSlot = .inspiration, reduceMotion: Bool = false,
                appearance: PanelAppearance = .dark) {
        var seen = Set<PanelSlot>()
        // Existing orders placed search among the six tabs. Replace that slot once.
        let migrated = order.contains(.fileShelf) ? order.filter { $0 != .globalSearch } : order.map { $0 == .globalSearch ? .fileShelf : $0 }
        self.order = (migrated + PanelSlot.navigationSlots).filter { seen.insert($0).inserted }
        self.defaultSlot = defaultSlot.isAvailable ? defaultSlot : .inspiration
        self.reduceMotion = reduceMotion
        self.appearance = appearance
    }

    public mutating func move(_ slot: PanelSlot, by distance: Int) {
        guard let from = order.firstIndex(of: slot), order.indices.contains(from + distance) else { return }
        order.swapAt(from, from + distance)
    }
}

public struct PanelPreferencesStore {
    private let defaults: UserDefaults
    private let key = "jotbloom.panel.preferences.v1"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> PanelPreferences {
        let record = defaults.dictionary(forKey: key) ?? [:]
        var order = (record["order"] as? [String] ?? []).compactMap(PanelSlot.init(rawValue:))
        // Migrate the former default only; saved custom arrangements keep their order.
        let oldDefault: [PanelSlot] = [.inspiration, .clipboard, .prompts, .inspirationLibrary, .chat, .fileShelf]
        if (record["navigationOrderVersion"] as? Int ?? 1) < 2,
           PanelPreferences(order: order).order == oldDefault {
            order = PanelSlot.navigationSlots
        }
        return PanelPreferences(
            order: order,
            defaultSlot: (record["default"] as? String).flatMap(PanelSlot.init(rawValue:)) ?? .inspiration,
            reduceMotion: record["reduceMotion"] as? Bool ?? false,
            appearance: (record["appearance"] as? String).flatMap(PanelAppearance.init(rawValue:)) ?? .dark
        )
    }

    public func save(_ preferences: PanelPreferences) {
        defaults.set(["order": preferences.order.map(\.rawValue),
                      "navigationOrderVersion": 2,
                      "default": preferences.defaultSlot.rawValue,
                      "reduceMotion": preferences.reduceMotion,
                      "appearance": preferences.appearance.rawValue], forKey: key)
    }
}
