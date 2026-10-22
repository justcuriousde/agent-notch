import SwiftUI
import AVFoundation

struct FaceCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    final class Preview: NSView {
        let preview = AVCaptureVideoPreviewLayer()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            preview.videoGravity = .resizeAspectFill
            layer?.addSublayer(preview)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() { super.layout(); preview.frame = bounds }
    }
    func makeNSView(context: Context) -> Preview {
        let view = Preview()
        view.preview.session = session
        if let connection = view.preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        return view
    }
    func updateNSView(_ nsView: Preview, context: Context) {
        if nsView.preview.session !== session { nsView.preview.session = session }
        if let connection = nsView.preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }
    static func dismantleNSView(_ nsView: Preview, coordinator: ()) { nsView.preview.session = nil }
}

struct FaceScanPortrait: View {
    @ObservedObject private var face = FaceRecognitionManager.shared
    var size: CGFloat = 190
    var body: some View {
        ZStack {
            Circle().fill(.black)
            if face.running {
                FaceCameraPreview(session: face.engine.session)
                    .clipShape(Circle()).padding(10)
            } else {
                Image(systemName: face.succeeded ? "checkmark" : "faceid")
                    .font(.system(size: size * 0.38, weight: .light))
                    .foregroundStyle(face.succeeded ? .green : .white)
            }
            Circle().stroke(.white.opacity(0.12), lineWidth: 4)
            Circle().trim(from: 0, to: face.progress)
                .stroke(.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: face.progress)
            ForEach(0..<48, id: \.self) { tick in
                Capsule().fill(Double(tick) / 48 < face.progress ? Color.green : Color.white.opacity(0.2))
                    .frame(width: 2, height: 6).offset(y: -size / 2 - 6)
                    .rotationEffect(.degrees(Double(tick) * 7.5))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(face.running ? "Live camera face scan" : face.succeeded ? "Face scan complete" : "Face setup")
    }
}

struct FaceEnrollmentView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var face = FaceRecognitionManager.shared
    @State private var started = false
    @State private var completed = false

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Text(completed ? "Face setup complete" : "Set Up Your Face").font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }
            }
            FaceScanPortrait().padding(.vertical, 14)
            Text(started ? face.message : "Position your face in the circle. Follow the head-turn and blink instructions.")
                .font(.headline).multilineTextAlignment(.center).frame(height: 50)
            if face.running {
                ProgressView(value: face.progress).tint(.green)
                Button("Cancel scan") { face.cancel(); started = false }
            } else if completed {
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            } else {
                Button(started ? "Try Again" : "Begin Face Scan") {
                    started = true
                    face.begin(enrolling: true) { passed in completed = passed }
                }.buttonStyle(.borderedProminent)
            }
            Text("Your facial feature template is saved in this Mac’s Keychain. Camera frames are processed locally and are not saved or uploaded.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("This uses a 2D camera. Motion checks can discourage simple photo attacks, but cannot guarantee protection against video, deepfakes or masks. Use Touch ID or your password for sensitive actions.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(30).frame(width: 440)
        .onDisappear { face.cancel() }
    }
}
