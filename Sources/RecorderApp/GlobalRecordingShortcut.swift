import Foundation
import Combine
import Carbon.HIToolbox
import RecorderCore

private let recorderHotKeySignature: OSType = 0x52454352 // "RECR"

private let recorderHotKeyHandler: EventHandlerUPP = { _, _, userData in
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<GlobalHotKeyManager>
        .fromOpaque(userData)
        .takeUnretainedValue()
    manager.invoke()
    return noErr
}

final class GlobalHotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    var isRegistered: Bool { hotKeyRef != nil }

    func registerCommandL(action: @escaping () -> Void) throws {
        guard hotKeyRef == nil else { return }
        self.action = action

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
            self.action = nil
            throw GlobalHotKeyError.registrationFailed(handlerStatus)
        }
        eventHandlerRef = installedHandler

        var registeredHotKey: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: recorderHotKeySignature, id: 1)
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_L),
            UInt32(cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard hotKeyStatus == noErr else {
            if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
            eventHandlerRef = nil
            self.action = nil
            throw GlobalHotKeyError.registrationFailed(hotKeyStatus)
        }
        hotKeyRef = registeredHotKey
    }

    func invoke() {
        action?()
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
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
            try hotKey.registerCommandL { [weak self] in
                Task { @MainActor in
                    await self?.toggleRecording()
                }
            }
        } catch {
            coordinator.presentedError = error.localizedDescription
        }
    }

    private func toggleRecording() async {
        guard !handlingShortcut else { return }
        handlingShortcut = true
        defer { handlingShortcut = false }

        if coordinator.activeRecording != nil {
            await coordinator.stop()
            return
        }

        let configuration = RecorderShortcutPreferences.configuration()
        if configuration.mode == .screen {
            guard PermissionManager.hasScreenCaptureAccess else {
                coordinator.presentedError = "⌘L could not start: enable Recorder under System Settings → Privacy & Security → Screen & System Audio Recording."
                return
            }
            guard configuration.capturesSystemAudio || configuration.capturesMicrophone else {
                coordinator.presentedError = "⌘L could not start: enable system audio or microphone in Shortcut Recording settings."
                return
            }
        } else if configuration.capturesSystemAudio,
                  !PermissionManager.hasScreenCaptureAccess {
            coordinator.presentedError = "⌘L could not start meeting audio: enable Screen & System Audio Recording permission, or disable system audio in Shortcut Recording settings."
            return
        }
        await coordinator.start(configuration: configuration)
    }
}

private enum GlobalHotKeyError: LocalizedError {
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let status):
            let systemMessage = NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status)
            ).localizedDescription
            return "Recorder could not register the global ⌘L shortcut (\(systemMessage)). Another app may already own it."
        }
    }
}
