import XCTest
@testable import RecorderCore

final class DeviceCatalogTests: XCTestCase {
    func testPrefersMacBookAirMicrophone() {
        let devices = [
            MediaDevice(id: "external", name: "USB Microphone"),
            MediaDevice(id: "airpods", name: "Mayank's AirPods Pro Microphone"),
            MediaDevice(id: "internal", name: "MacBook Air Microphone")
        ]

        XCTAssertEqual(DeviceCatalog.preferredMicrophoneID(in: devices), "internal")
    }

    func testPrefersBuiltInFaceTimeCamera() {
        let devices = [
            MediaDevice(id: "continuity", name: "iPhone Camera"),
            MediaDevice(id: "external", name: "USB Camera"),
            MediaDevice(id: "internal", name: "FaceTime HD Camera")
        ]

        XCTAssertEqual(DeviceCatalog.preferredCameraID(in: devices), "internal")
    }
}
