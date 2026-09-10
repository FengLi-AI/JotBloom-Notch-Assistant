import Carbon.HIToolbox
import Foundation
import JotBloomCore
import OSLog

@MainActor
final class HotKeyManager {
    private static let hotKeySignature: OSType = 0x4A_42_4C_4D // JBLM

    private let logger = Logger(subsystem: "com.jotbloom.mengsheng", category: "hotkey")
    private let onPressed: () -> Void
    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private var activeIdentifier: UInt32 = 0
    private var nextIdentifier: UInt32 = 1
    private(set) var shortcut = Shortcut.standard

    private(set) var isRegistered = false

    init(onPressed: @escaping () -> Void) {
        self.onPressed = onPressed
    }

    func registerDefaultShortcut() -> OSStatus {
        register(.standard)
    }

    func register(_ candidate: Shortcut) -> OSStatus {
        guard candidate.isValid else { return OSStatus(paramErr) }
        if isRegistered, candidate.keyCode == shortcut.keyCode, candidate.modifiers == shortcut.modifiers { return noErr }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = eventHandlerReference != nil ? noErr : InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventType,
            userData,
            &eventHandlerReference
        )
        guard handlerStatus == noErr else {
            logger.error("Hot key event handler installation failed with status: \(handlerStatus, privacy: .public)")
            return handlerStatus
        }

        let identifier = EventHotKeyID(
            signature: Self.hotKeySignature,
            id: nextIdentifier
        )
        nextIdentifier &+= 1
        var newReference: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            candidate.keyCode,
            candidate.modifiers,
            identifier,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &newReference
        )

        guard registrationStatus == noErr else {
            logger.error("Shortcut registration failed with status: \(registrationStatus, privacy: .public)")
            return registrationStatus
        }

        let oldReference = hotKeyReference
        hotKeyReference = newReference
        activeIdentifier = identifier.id
        shortcut = candidate
        isRegistered = true
        if let oldReference { UnregisterEventHotKey(oldReference) }
        logger.info("Shortcut registered")
        return noErr
    }

    func unregister() {
        isRegistered = false
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
            self.hotKeyReference = nil
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
            self.eventHandlerReference = nil
        }
    }

    private func handlePressedEvent(_ event: EventRef?) -> OSStatus {
        guard let event else { return OSStatus(eventNotHandledErr) }

        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr,
              identifier.signature == Self.hotKeySignature,
              identifier.id == activeIdentifier else {
            return OSStatus(eventNotHandledErr)
        }

        onPressed()
        return noErr
    }

    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
        return manager.handlePressedEvent(event)
    }
}
