import SwiftUI
import RecorderCore

struct RecordingSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: RecordingCoordinator
    let mode: RecordingMode

    @State private var microphones = DeviceCatalog.microphones()
    @State private var cameras = DeviceCatalog.cameras()
    @State private var screenSources: [ScreenSource] = []
    @State private var microphoneID: String?
    @State private var cameraID: String?
    @State private var selectedSourceID: UInt32?
    @State private var screenTarget: ScreenTarget = .display
    @State private var capturesSystemAudio = true
    @State private var capturesMicrophone = true
    @State private var resolution = Resolution.fullHD
    @State private var framesPerSecond = 30
    @State private var regionX = 0.0
    @State private var regionY = 0.0
    @State private var regionWidth = 1280.0
    @State private var regionHeight = 720.0
    @State private var loadingSources = false

    enum Resolution: String, CaseIterable, Identifiable {
        case hd = "1280 × 720"
        case fullHD = "1920 × 1080"
        case quadHD = "2560 × 1440"
        var id: Self { self }
        var dimensions: (Int, Int) {
            switch self {
            case .hd: (1280, 720)
            case .fullHD: (1920, 1080)
            case .quadHD: (2560, 1440)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: modeIcon).font(.largeTitle).foregroundStyle(.red)
                VStack(alignment: .leading) {
                    Text("New \(mode.displayName) Recording").font(.title2.bold())
                    Text("Files remain in your local recording library.").foregroundStyle(.secondary)
                }
            }

            Form {
                if mode == .camera {
                    Picker("Camera", selection: $cameraID) {
                        ForEach(cameras) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if mode != .screen || capturesMicrophone {
                    Picker("Microphone", selection: $microphoneID) {
                        ForEach(microphones) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if mode == .screen {
                    Picker("Capture", selection: $screenTarget) {
                        Text("Entire display").tag(ScreenTarget.display)
                        Text("Window").tag(ScreenTarget.window)
                        Text("Region").tag(ScreenTarget.region)
                    }
                    Picker("Source", selection: $selectedSourceID) {
                        ForEach(filteredSources) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .overlay { if loadingSources { ProgressView() } }
                    Toggle("Record system audio", isOn: $capturesSystemAudio)
                    Toggle("Record microphone", isOn: $capturesMicrophone)
                    if screenTarget == .region {
                        Grid(alignment: .leading) {
                            GridRow {
                                Text("Origin")
                                TextField("X", value: $regionX, format: .number).frame(width: 80)
                                TextField("Y", value: $regionY, format: .number).frame(width: 80)
                            }
                            GridRow {
                                Text("Size")
                                TextField("Width", value: $regionWidth, format: .number).frame(width: 80)
                                TextField("Height", value: $regionHeight, format: .number).frame(width: 80)
                            }
                        }
                    }
                }
                if mode != .audio {
                    Picker("Resolution", selection: $resolution) {
                        ForEach(Resolution.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Frame rate", selection: $framesPerSecond) {
                        Text("24 fps").tag(24)
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Start Recording") {
                    Task {
                        await coordinator.start(configuration: configuration)
                        if coordinator.activeRecording != nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!configurationIsValid)
            }
        }
        .padding(24)
        .frame(width: 540)
        .task {
            microphoneID = microphones.first?.id
            cameraID = cameras.first?.id
            guard mode == .screen else { return }
            loadingSources = true
            screenSources = (try? await DeviceCatalog.screenSources()) ?? []
            selectedSourceID = filteredSources.first?.id
            loadingSources = false
        }
        .onChange(of: screenTarget) { _, _ in selectedSourceID = filteredSources.first?.id }
    }

    private var configuration: CaptureConfiguration {
        let dimensions = resolution.dimensions
        let selected = screenSources.first { $0.id == selectedSourceID }
        return CaptureConfiguration(
            mode: mode,
            microphoneID: microphoneID,
            cameraID: cameraID,
            displayID: selected?.kind == .display ? selected?.id : screenSources.first(where: { $0.kind == .display })?.id,
            windowID: selected?.kind == .window ? selected?.id : nil,
            screenTarget: screenTarget,
            region: screenTarget == .region ? CaptureRegion(x: regionX, y: regionY, width: regionWidth, height: regionHeight) : nil,
            capturesSystemAudio: mode == .screen && capturesSystemAudio,
            capturesMicrophone: mode != .screen || capturesMicrophone,
            width: dimensions.0,
            height: dimensions.1,
            framesPerSecond: framesPerSecond
        )
    }

    private var filteredSources: [ScreenSource] {
        switch screenTarget {
        case .window: screenSources.filter { $0.kind == .window }
        case .display, .region: screenSources.filter { $0.kind == .display }
        }
    }

    private var configurationIsValid: Bool {
        switch mode {
        case .audio: microphoneID != nil
        case .camera: cameraID != nil && (!capturesMicrophone || microphoneID != nil)
        case .screen: selectedSourceID != nil && (capturesSystemAudio || capturesMicrophone)
        }
    }

    private var modeIcon: String {
        switch mode {
        case .audio: "waveform.circle.fill"
        case .camera: "video.circle.fill"
        case .screen: "rectangle.inset.filled.and.person.filled"
        }
    }
}
