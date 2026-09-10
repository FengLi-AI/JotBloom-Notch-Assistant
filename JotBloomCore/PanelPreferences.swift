import Foundation

/// Stable navigation identities; reserved features never become valid default routes.
public enum PanelSlot: String, Codable, CaseIterable {
    case inspiration, clipboard, prompts, inspirationLibrary, chat, globalSearch

    public var isAvailable: Bool { true }
    public var title: String {
        switch self {
        case .inspiration: return "灵感"
        case .clipboard: return "剪贴板"
        case .prompts: return "提示词"
        case .inspirationLibrary: return "灵感库"
        case .chat: return "对话"
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
        case .globalSearch: return "magnifyingglass"
        }
    }
}

public struct PanelPreferences: Equatable {
    public private(set) var order: [PanelSlot]
    public var defaultSlot: PanelSlot {
        didSet { if !defaultSlot.isAvailable { defaultSlot = .inspiration } }
    }
    public var reduceMotion: Bool

    public init(order: [PanelSlot] = PanelSlot.allCases,
                defaultSlot: PanelSlot = .inspiration, reduceMotion: Bool = false) {
        var seen = Set<PanelSlot>()
        self.order = (order + PanelSlot.allCases).filter { seen.insert($0).inserted }
        self.defaultSlot = defaultSlot.isAvailable ? defaultSlot : .inspiration
        self.reduceMotion = reduceMotion
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
        return PanelPreferences(
            order: (record["order"] as? [String] ?? []).compactMap(PanelSlot.init(rawValue:)),
            defaultSlot: (record["default"] as? String).flatMap(PanelSlot.init(rawValue:)) ?? .inspiration,
            reduceMotion: record["reduceMotion"] as? Bool ?? false
        )
    }

    public func save(_ preferences: PanelPreferences) {
        defaults.set(["order": preferences.order.map(\.rawValue),
                      "default": preferences.defaultSlot.rawValue,
                      "reduceMotion": preferences.reduceMotion], forKey: key)
    }
}
