import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics

public enum DeviceCatalog {
    public static func microphones() -> [MediaDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        return preferredMicrophoneOrder(
            discovery.devices.map { MediaDevice(id: $0.uniqueID, name: $0.localizedName) }
        )
    }

    public static func cameras() -> [MediaDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return preferredCameraOrder(
            discovery.devices.map { MediaDevice(id: $0.uniqueID, name: $0.localizedName) }
        )
    }

    public static func preferredMicrophoneID(in devices: [MediaDevice]) -> String? {
        preferredMicrophoneOrder(devices).first?.id
    }

    public static func preferredCameraID(in devices: [MediaDevice]) -> String? {
        preferredCameraOrder(devices).first?.id
    }

    public static func screenSources() async throws -> [ScreenSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displays = content.displays.map {
            ScreenSource(id: $0.displayID, name: "Display \($0.displayID)", kind: .display)
        }
        let windows = content.windows.compactMap { window -> ScreenSource? in
            guard let application = window.owningApplication,
                  window.frame.width > 100,
                  window.frame.height > 80 else { return nil }
            let title = window.title?.isEmpty == false ? window.title! : "Untitled Window"
            return ScreenSource(
                id: window.windowID,
                name: "\(application.applicationName) — \(title)",
                kind: .window
            )
        }
        return displays + windows
    }

    static func preferredMicrophoneOrder(_ devices: [MediaDevice]) -> [MediaDevice] {
        devices.sortedByPreference { device in
            let name = device.name.lowercased()
            if name.contains("macbook air") && name.contains("microphone") { return 0 }
            if name.contains("macbook") && name.contains("microphone") { return 1 }
            if name.contains("built-in") && name.contains("microphone") { return 2 }
            if name.contains("internal") && name.contains("microphone") { return 3 }
            if name.contains("microphone") { return 10 }
            return 20
        }
    }

    static func preferredCameraOrder(_ devices: [MediaDevice]) -> [MediaDevice] {
        devices.sortedByPreference { device in
            let name = device.name.lowercased()
            if name.contains("facetime") { return 0 }
            if name.contains("macbook air") && name.contains("camera") { return 1 }
            if name.contains("macbook") && name.contains("camera") { return 2 }
            if name.contains("built-in") && name.contains("camera") { return 3 }
            if name.contains("internal") && name.contains("camera") { return 4 }
            if name.contains("camera") { return 10 }
            return 20
        }
    }
}

private extension Array where Element == MediaDevice {
    func sortedByPreference(_ score: (MediaDevice) -> Int) -> [MediaDevice] {
        sorted {
            let leftScore = score($0)
            let rightScore = score($1)
            if leftScore != rightScore { return leftScore < rightScore }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

public enum PermissionManager {
    public static func requestMicrophone() async -> Bool {
        await requestMedia(.audio)
    }

    public static func requestCamera() async -> Bool {
        await requestMedia(.video)
    }

    public static var hasScreenCaptureAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    public static func requestScreenCaptureAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    private static func requestMedia(_ mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: mediaType)
        default:
            false
        }
    }
}
