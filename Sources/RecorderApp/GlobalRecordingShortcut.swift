import Foundation
import Combine
import Carbon.HIToolbox
import RecorderCore

private let recorderHotKeySignature: OSType = 0x52454352 // "RECR"

private struct GlobalHotKeyDefinition {
    let id: UInt32
    let keyCode: UInt32
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
                    UInt32(cmdKey),
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

    private func unregisterAll() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        actions.removeAll()
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        eventHandlerRef = nil
    }
}

@MainActor
final class ShortcutRecordingController: ObservableObject {
    private let coordinator: RecordingCoordinator
    private let hotKey = GlobalHotKeyManager()
    private var handlingShortcut = false

    init(coordinator: RecordingCoordinator) {
        self.coordinator = coordinator
    }

    func startListening() {
        guard !hotKey.isRegistered else { return }
        do {
            try hotKey.register([
                shortcut(id: 1, keyCode: UInt32(kVK_ANSI_L), name: "⌘L", mode: .audio),
                shortcut(id: 2, keyCode: UInt32(kVK_ANSI_N), name: "⌘N", mode: .screen),
                shortcut(id: 3, keyCode: UInt32(kVK_ANSI_B), name: "⌘B", mode: .camera)
            ])
        } catch {
            coordinator.presentedError = error.localizedDescription
        }
    }

    private func shortcut(
        id: UInt32,
        keyCode: UInt32,
        name: String,
        mode: RecordingMode
    ) -> GlobalHotKeyDefinition {
        GlobalHotKeyDefinition(id: id, keyCode: keyCode, displayName: name) { [weak self] in
            Task { @MainActor in
                await self?.toggleRecording(mode: mode)
            }
        }
    }

    private func toggleRecording(mode: RecordingMode) async {
        guard !handlingShortcut else { return }
        handlingShortcut = true
        defer { handlingShortcut = false }

        if coordinator.activeRecording != nil {
            await coordinator.stop()
            return
        }

        let configuration = RecorderShortcutPreferences.configuration(for: mode)
        guard await permissionsAreAvailable(for: configuration) else { return }
        await coordinator.start(configuration: configuration)
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
                coordinator.presentedError = "⌘B could not start: enable Recorder under System Settings → Privacy & Security → Camera."
                return false
            }
        }
        if configuration.mode == .screen,
           !configuration.capturesSystemAudio,
           !configuration.capturesMicrophone {
            coordinator.presentedError = "⌘N could not start: enable system audio or microphone in Shortcut Recording settings."
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
