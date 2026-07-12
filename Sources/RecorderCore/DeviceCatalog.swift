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
        return discovery.devices.map { MediaDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    public static func cameras() -> [MediaDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map { MediaDevice(id: $0.uniqueID, name: $0.localizedName) }
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
}

public enum PermissionManager {
    public static func requestMicrophone() async -> Bool {
        await requestMedia(.audio)
    }

    public static func requestCamera() async -> Bool {
        await requestMedia(.video)
    }

    public static func requestScreenCapture() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
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
