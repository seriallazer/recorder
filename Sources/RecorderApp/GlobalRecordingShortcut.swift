import Foundation
import Combine
import Carbon.HIToolbox
import RecorderCore

private let recorderHotKeySignature: OSType = 0x52454352 // "RECR"

private struct GlobalHotKeyDefinition {
    let id: UInt32
    let keyCode: UInt32
    let modifiers: UInt32
    let displayName: String
    let action: () -> Void
}

private let recorderHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<GlobalHotKeyManager>
        .fromOpaque(userData)
        .takeUnretainedValue()
    return manager.invoke(event: event)
}

final class GlobalHotKeyManager {
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]

    var isRegistered: Bool { !hotKeyRefs.isEmpty }

    fileprivate func register(_ definitions: [GlobalHotKeyDefinition]) throws {
        guard !isRegistered else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        var installedHandler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            recorderHotKeyHandler,
            1,
            &eventType,
            context,
            &installedHandler
        )
        guard handlerStatus == noErr else {
            throw GlobalHotKeyError.registrationFailed("keyboard handler", handlerStatus)
        }
        eventHandlerRef = installedHandler

        do {
            for definition in definitions {
                var registeredHotKey: EventHotKeyRef?
                let hotKeyID = EventHotKeyID(
                    signature: recorderHotKeySignature,
                    id: definition.id
                )
                let status = RegisterEventHotKey(
                    definition.keyCode,
                    definition.modifiers,
                    hotKeyID,
                    GetApplicationEventTarget(),
                    0,
                    &registeredHotKey
                )
                guard status == noErr, let registeredHotKey else {
                    throw GlobalHotKeyError.registrationFailed(
                        definition.displayName,
                        status
                    )
                }
                hotKeyRefs.append(registeredHotKey)
                actions[definition.id] = definition.action
            }
        } catch {
            unregisterAll()
            throw error
        }
    }

    func invoke(event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID(signature: 0, id: 0)
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr,
              hotKeyID.signature == recorderHotKeySignature,
              let action = actions[hotKeyID.id] else {
            return OSStatus(eventNotHandledErr)
        }
        action()
        return noErr
    }

    deinit {
        unregisterAll()
    }

    fileprivate func unregisterAll() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        actions.removeAll()
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        eventHandlerRef = nil
    }
}

@MainActor
final class ShortcutRecordingController: ObservableObject {
    @Published private(set) var registeredShortcuts = RecorderShortcutPreferences.shortcuts()

    private let coordinator: RecordingCoordinator
    private let hotKey = GlobalHotKeyManager()
    private var handlingShortcut = false
    private var defaultsObserver: NSObjectProtocol?

    init(coordinator: RecordingCoordinator) {
        self.coordinator = coordinator
    }

    func startListening() {
        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reloadShortcuts() }
            }
        }
        reloadShortcuts()
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    private func reloadShortcuts() {
        let requested = RecorderShortcutPreferences.shortcuts()
        do {
            try switchRegistration(to: requested)
        } catch {
            if hotKey.isRegistered {
                try? RecorderShortcutPreferences.save(shortcuts: registeredShortcuts)
            }
            coordinator.presentedError = error.localizedDescription
        }
    }

    func apply(shortcuts requested: RecordingShortcutSet) throws {
        let previous = registeredShortcuts
        try switchRegistration(to: requested)
        do {
            try RecorderShortcutPreferences.save(shortcuts: requested)
        } catch {
            try? switchRegistration(to: previous)
            throw error
        }
    }

    private func switchRegistration(to requested: RecordingShortcutSet) throws {
        guard requested.hasUniqueShortcuts else {
            throw ShortcutPreferenceError.duplicateShortcuts
        }
        guard requested != registeredShortcuts || !hotKey.isRegistered else { return }
        let previous = hotKey.isRegistered ? registeredShortcuts : nil
        hotKey.unregisterAll()
        do {
            try hotKey.register(definitions(for: requested))
            registeredShortcuts = requested
        } catch {
            if let previous {
                try? hotKey.register(definitions(for: previous))
                registeredShortcuts = previous
            }
            throw error
        }
    }

    private func definitions(
        for shortcuts: RecordingShortcutSet
    ) -> [GlobalHotKeyDefinition] {
        [
            shortcut(id: 1, configuration: shortcuts.audio, mode: .audio),
            shortcut(id: 2, configuration: shortcuts.screen, mode: .screen),
            shortcut(id: 3, configuration: shortcuts.camera, mode: .camera)
        ]
    }

    private func shortcut(
        id: UInt32,
        configuration: RecordingKeyboardShortcut,
        mode: RecordingMode
    ) -> GlobalHotKeyDefinition {
        GlobalHotKeyDefinition(
            id: id,
            keyCode: keyCode(for: configuration.key),
            modifiers: carbonModifiers(for: configuration.modifiers),
            displayName: configuration.displayText
        ) { [weak self] in
            Task { @MainActor in
                await self?.toggleRecording(mode: mode)
            }
        }
    }

    private func toggleRecording(mode: RecordingMode) async {
        guard !handlingShortcut else { return }
        handlingShortcut = true
        defer { handlingShortcut = false }

        switch RecorderShortcutPreferences.action(
            activeMode: coordinator.activeRecording?.mode,
            requestedMode: mode
        ) {
        case .stop:
            await coordinator.stop()
            return
        case .blocked(let activeMode):
            coordinator.presentedError = blockedMessage(
                activeMode: activeMode,
                requestedMode: mode
            )
            return
        case .start:
            break
        }

        let configuration = RecorderShortcutPreferences.configuration(for: mode)
        guard await permissionsAreAvailable(for: configuration) else { return }
        await coordinator.start(configuration: configuration)
    }

    private func blockedMessage(
        activeMode: RecordingMode,
        requestedMode: RecordingMode
    ) -> String {
        let activeShortcut = shortcutName(for: activeMode)
        let requestedShortcut = shortcutName(for: requestedMode)
        return "A \(activeMode.displayName.lowercased()) recording is already running. Stop it with \(activeShortcut) or the Recorder controls before using \(requestedShortcut)."
    }

    private func shortcutName(for mode: RecordingMode) -> String {
        registeredShortcuts[mode].displayText
    }

    private func carbonModifiers(
        for modifiers: RecordingShortcutModifiers
    ) -> UInt32 {
        switch modifiers {
        case .command: UInt32(cmdKey)
        case .commandOption: UInt32(cmdKey | optionKey)
        case .commandShift: UInt32(cmdKey | shiftKey)
        case .commandControl: UInt32(cmdKey | controlKey)
        case .commandOptionShift: UInt32(cmdKey | optionKey | shiftKey)
        case .commandOptionControl: UInt32(cmdKey | optionKey | controlKey)
        case .controlOption: UInt32(controlKey | optionKey)
        }
    }

    private func keyCode(for key: String) -> UInt32 {
        switch key.uppercased() {
        case "A": UInt32(kVK_ANSI_A)
        case "B": UInt32(kVK_ANSI_B)
        case "C": UInt32(kVK_ANSI_C)
        case "D": UInt32(kVK_ANSI_D)
        case "E": UInt32(kVK_ANSI_E)
        case "F": UInt32(kVK_ANSI_F)
        case "G": UInt32(kVK_ANSI_G)
        case "H": UInt32(kVK_ANSI_H)
        case "I": UInt32(kVK_ANSI_I)
        case "J": UInt32(kVK_ANSI_J)
        case "K": UInt32(kVK_ANSI_K)
        case "L": UInt32(kVK_ANSI_L)
        case "M": UInt32(kVK_ANSI_M)
        case "N": UInt32(kVK_ANSI_N)
        case "O": UInt32(kVK_ANSI_O)
        case "P": UInt32(kVK_ANSI_P)
        case "Q": UInt32(kVK_ANSI_Q)
        case "R": UInt32(kVK_ANSI_R)
        case "S": UInt32(kVK_ANSI_S)
        case "T": UInt32(kVK_ANSI_T)
        case "U": UInt32(kVK_ANSI_U)
        case "V": UInt32(kVK_ANSI_V)
        case "W": UInt32(kVK_ANSI_W)
        case "X": UInt32(kVK_ANSI_X)
        case "Y": UInt32(kVK_ANSI_Y)
        case "Z": UInt32(kVK_ANSI_Z)
        default: UInt32(kVK_ANSI_M)
        }
    }

    private func permissionsAreAvailable(
        for configuration: CaptureConfiguration
    ) async -> Bool {
        if configuration.mode == .screen || configuration.capturesSystemAudio {
            guard PermissionManager.hasScreenCaptureAccess else {
                coordinator.presentedError = "The shortcut could not start: enable Recorder under System Settings → Privacy & Security → Screen & System Audio Recording."
                return false
            }
        }
        if configuration.capturesMicrophone {
            guard await PermissionManager.requestMicrophone() else {
                coordinator.presentedError = "The shortcut could not start: enable Recorder under System Settings → Privacy & Security → Microphone."
                return false
            }
        }
        if configuration.mode == .camera {
            guard await PermissionManager.requestCamera() else {
                coordinator.presentedError = "\(shortcutName(for: .camera)) could not start: enable Recorder under System Settings → Privacy & Security → Camera."
                return false
            }
        }
        if configuration.mode == .screen,
           !configuration.capturesSystemAudio,
           !configuration.capturesMicrophone {
            coordinator.presentedError = "\(shortcutName(for: .screen)) could not start: enable system audio or microphone in Shortcut Recording settings."
            return false
        }
        return true
    }
}

private enum GlobalHotKeyError: LocalizedError {
    case registrationFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let shortcut, let status):
            let systemMessage = NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status)
            ).localizedDescription
            return "Recorder could not register the global \(shortcut) shortcut (\(systemMessage)). Another app may already own it."
        }
    }
}
