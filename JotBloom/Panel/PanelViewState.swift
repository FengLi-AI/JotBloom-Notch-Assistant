import AppKit
import Combine
import JotBloomCore
import SwiftUI

enum PanelTab: String, CaseIterable {
    case inspiration
    case clipboard
    case prompts
    case chat
    case inspirationLibrary
    case globalSearch
}

enum InspirationDetailOrigin: Equatable {
    case inspirationLibrary
    case globalSearch(resultID: SearchResultID, queryRevision: UInt64)
}

@MainActor
final class PanelViewState: ObservableObject {
    private let preferencesStore: PanelPreferencesStore
    @Published var preferences: PanelPreferences { didSet { preferencesStore.save(preferences) } }
    @Published private(set) var isSettingsOpen = false
    @Published var isPromptEditorOpen = false
    @Published var settingsSection = "general"
    @Published private(set) var keyboardNavigation = false

    func useKeyboardNavigation() { if !keyboardNavigation { keyboardNavigation = true } }
    func usePointerNavigation() { if keyboardNavigation { keyboardNavigation = false } }
    private var expansionBeforeSettings = false
    private var isolatedPreferencesSuite: String?

    init() {
        var defaults = UserDefaults.standard
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment.keys.contains(where: { $0.hasPrefix("JOTBLOOM_STAGE") && $0.hasSuffix("_SMOKE") })
            || environment["JOTBLOOM_DEBUG_DATA_DIRECTORY"] != nil {
            // Debug harnesses must not inherit or change the user's preferred default tab.
            let suite = "JotBloom.Debug.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            isolatedPreferencesSuite = suite
        }
#endif
        preferencesStore = PanelPreferencesStore(defaults: defaults)
        preferences = preferencesStore.load()
    }

    deinit {
        if let suite = isolatedPreferencesSuite { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    var reducesMotion: Bool {
        preferences.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func openSettings() {
        guard !isSettingsOpen else { return }
        expansionBeforeSettings = isExpanded
        isSettingsOpen = true
        setExpanded(true)
    }

    func closeSettings() {
        guard isSettingsOpen else { return }
        isSettingsOpen = false
        setExpanded(expansionBeforeSettings)
    }

    private func setExpanded(_ value: Bool) {
        withAnimation(reducesMotion ? nil : BloomTheme.layoutAnimation) { isExpanded = value }
    }
    @Published private(set) var notchHeight: CGFloat = NSStatusBar.system.thickness
    @Published private(set) var notchWidth: CGFloat = PanelGeometry.fallbackNotchWidth
    @Published private(set) var inputHeight: CGFloat = PanelGeometry.referenceInspirationInputHeight
    @Published private(set) var isExpanded = false
    @Published private(set) var selectedTab: PanelTab = .inspiration
    @Published private(set) var inspirationDetailOrigin: InspirationDetailOrigin?

    func update(metrics: ScreenMetrics) {
        notchHeight = PanelGeometry.notchHeight(for: metrics)
        notchWidth = PanelGeometry.notchWidth(for: metrics)
        inputHeight = PanelGeometry.inspirationInputHeight(for: metrics)
    }

    func toggleExpansion() {
        guard !isSettingsOpen else { return }
        setExpanded(!isExpanded)
    }

    func expand() {
        setExpanded(true)
    }

    func collapse() {
        guard !isSettingsOpen else { return }
        setExpanded(false)
    }

    func select(_ tab: PanelTab) {
        selectedTab = tab
        if tab == .globalSearch { expand() }
    }

    func beginInspirationDetail(from origin: InspirationDetailOrigin) {
        inspirationDetailOrigin = origin
    }

    func finishInspirationDetail() {
        inspirationDetailOrigin = nil
    }

    func resetForPresentation() {
        keyboardNavigation = false
        selectedTab = PanelTab(rawValue: preferences.defaultSlot.rawValue) ?? .inspiration
        isSettingsOpen = false
        isExpanded = selectedTab == .globalSearch
        inspirationDetailOrigin = nil
    }
}
