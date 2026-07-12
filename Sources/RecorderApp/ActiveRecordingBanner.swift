import SwiftUI
import AVFoundation
import RecorderCore

struct ActiveRecordingBanner: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    let recording: RecordingManifest

    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(.red).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.state == .finalizing ? "Finalizing recording…" : "Recording \(recording.mode.displayName.lowercased())")
                    .fontWeight(.semibold)
                Text(TranscriptDocument.timestamp(coordinator.elapsedTime))
                    .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(coordinator.audioLevel))
                .progressViewStyle(.linear)
                .tint(coordinator.audioLevel > 0.85 ? .red : .green)
                .frame(width: 110)
                .help("Microphone level")
            Spacer()
            if recording.mode == .camera, let session = coordinator.cameraSession {
                CameraPreviewView(session: session).frame(width: 140, height: 80).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Button {
                Task { await coordinator.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(recording.state == .finalizing)
        }
        .padding(12)
        .background(.red.opacity(0.07))
    }
}

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewContainer {
        let view = PreviewContainer()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: PreviewContainer, context: Context) {
        nsView.previewLayer.session = session
    }

    final class PreviewContainer: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            previewLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }
}
