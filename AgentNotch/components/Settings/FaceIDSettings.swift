import SwiftUI
import LocalAuthentication
import AppKit

/// Authorizes the notch interface through local face matching or macOS recovery.
@MainActor
final class NotchAuthentication: ObservableObject {
    static let shared = NotchAuthentication()
    enum Phase: Equatable { case ready, authenticating, success, failed, cancelled }
    @Published private(set) var phase: Phase = .ready
    @Published private(set) var unlocked = false
    @Published private(set) var message = "Authenticate with Touch ID or your Mac password"
    private var context: LAContext?
    private var generation = UUID()
    private var sleepObserver: NSObjectProtocol?
    private var sessionObserver: NSObjectProtocol?

    private init() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.lock() } }
        sessionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.lock() } }
    }

    func lock() {
        generation = UUID()
        FaceRecognitionManager.shared.cancel()
        context?.invalidate()
        context = nil
        unlocked = false
        phase = .ready
        message = "Use your saved face, Touch ID or Mac password"
    }

    func authenticateWithFace(grantAccess: Bool = true) {
        guard phase != .authenticating else { return }
        generation = UUID()
        let attempt = generation
        phase = .authenticating
        message = "Look at the camera and follow the instructions"
        FaceRecognitionManager.shared.begin(enrolling: false) { [weak self] accepted in
            guard let self, self.generation == attempt else { return }
            self.phase = accepted ? .success : .failed
            self.message = FaceRecognitionManager.shared.message
            guard accepted else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(650))
                guard self.generation == attempt else { return }
                self.unlocked = grantAccess
            }
        }
    }

    func authenticate(reason: String, grantAccess: Bool = true) {
        guard phase != .authenticating else { return }
        let token = UUID()
        generation = token
        let request = LAContext()
        request.localizedCancelTitle = "Cancel"
        request.touchIDAuthenticationAllowableReuseDuration = 0
        var error: NSError?
        guard request.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            phase = .failed
            message = error?.localizedDescription ?? "Authentication is unavailable on this Mac."
            return
        }
        context = request
        phase = .authenticating
        message = "Confirm in the macOS authentication window"
        Task {
            do {
                let accepted = try await request.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                guard generation == token else { return }
                context = nil
                guard accepted else { phase = .failed; message = "Authentication was not accepted"; return }
                phase = .success
                message = "Done"
                // Let the checkmark complete before revealing private content.
                try? await Task.sleep(for: .milliseconds(650))
                guard generation == token else { return }
                unlocked = grantAccess
            } catch {
                guard generation == token else { return }
                context = nil
                let code = (error as? LAError)?.code
                phase = [.userCancel, .appCancel, .systemCancel].contains(code) ? .cancelled : .failed
                message = phase == .cancelled ? "Cancelled. Your content stays locked." : error.localizedDescription
            }
        }
    }
}

struct FaceIDEmblem: View {
    let phase: NotchAuthentication.Phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false
    private var scanning: Bool { phase == .authenticating }
    private var tint: Color { phase == .success ? .green : phase == .failed ? .orange : .white }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(tint.opacity(0.055))
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(tint.opacity(0.12), lineWidth: 1)
            Circle().stroke(tint.opacity(0.12), lineWidth: 3).padding(9)
            Circle().trim(from: 0, to: phase == .success ? 1 : 0.24)
                .stroke(AngularGradient(colors: [tint.opacity(0.1), tint], center: .center),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(rotating && scanning && !reduceMotion ? 360 : -90))
                .padding(9)
                .opacity(scanning || phase == .success ? 1 : 0)
            Image(systemName: phase == .success ? "checkmark" : phase == .failed ? "exclamationmark" : "faceid")
                .font(.system(size: phase == .success ? 37 : 46, weight: .light))
                .contentTransition(.symbolEffect(.replace))
                .scaleEffect(scanning && rotating && !reduceMotion ? 0.94 : 1)
        }
        .foregroundStyle(tint)
        .frame(width: 100, height: 100)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.78), value: phase)
        .onChange(of: scanning, initial: true) { _, active in
            rotating = false
            if active && !reduceMotion {
                withAnimation(.linear(duration: 1.45).repeatForever(autoreverses: false)) { rotating = true }
            }
        }
        .accessibilityLabel(phase == .success ? "Authentication complete" : scanning ? "Authenticating" : "Face ID style authentication")
    }
}

struct NotchLockView: View {
    @ObservedObject private var authentication = NotchAuthentication.shared
    @ObservedObject private var face = FaceRecognitionManager.shared
    var body: some View {
        VStack(spacing: 9) {
            if face.running {
                FaceScanPortrait(size: 90)
            } else {
                FaceIDEmblem(phase: authentication.phase).scaleEffect(0.8).frame(height: 80)
            }
            Text(authentication.phase == .success ? "Done" : "Unlock AgentNotch").font(.headline)
            Text(face.running ? face.message : authentication.message)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 300)
            HStack {
                if authentication.phase == .authenticating {
                    Button("Cancel") { authentication.lock() }
                } else if authentication.phase != .success {
                    if face.enrolled {
                        Button("Scan Face") { authentication.authenticateWithFace() }.buttonStyle(.borderedProminent)
                    }
                    Button("Use Mac Password") { authentication.authenticate(reason: "Unlock your notch content") }
                }
            }
        }
        .padding(.top, 38).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            face.refreshEnrollment()
            if face.enrolled && authentication.phase == .ready { authentication.authenticateWithFace() }
        }
    }
}

struct FaceIDSettings: View {
    @AppStorage("faceIDProtectNotch") private var protectNotch = false
    @ObservedObject private var authentication = NotchAuthentication.shared
    @ObservedObject private var face = FaceRecognitionManager.shared
    @State private var showingEnrollment = false
    @State private var managementBusy = false
    @State private var managementContext: LAContext?
    @State private var managementError: String?
    @State private var confirmingRemoval = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    if face.running { FaceScanPortrait(size: 150) }
                    else { FaceIDEmblem(phase: authentication.phase) }
                    Text(face.enrolled ? "Your face is enrolled" : "Set up your face")
                        .font(.title3.weight(.semibold))
                    Text(face.running ? face.message : "Camera recognition · On this Mac only")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 20)
                HStack {
                    Button(face.enrolled ? "Set Up Face Again" : "Set Up Face") {
                        authorizeManagement { authentication.lock(); showingEnrollment = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(managementBusy || face.running || authentication.phase == .authenticating)
                    if face.enrolled {
                        Button("Test Face Recognition") {
                            authentication.lock()
                            authentication.authenticateWithFace(grantAccess: false)
                        }.disabled(managementBusy || authentication.phase == .authenticating)
                        Button("Remove Face", role: .destructive) { confirmingRemoval = true }
                            .disabled(managementBusy || authentication.phase == .authenticating)
                    }
                    if authentication.phase == .authenticating {
                        Button("Cancel") { authentication.lock() }
                    }
                }
                if let managementError { Text(managementError).font(.caption).foregroundStyle(.orange) }
                if authentication.phase == .failed || authentication.phase == .success {
                    Text(authentication.message).font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Face ID · Camera Recognition") } footer: {
                Text("Enroll once, then the built-in camera compares your face with your saved template. Random head-turn and blink challenges are required. No camera frames are saved or uploaded; only facial feature vectors are stored in this Mac’s Keychain.")
            }
            Section {
                Toggle("Unlock notch content with my face", isOn: $protectNotch)
                    .disabled((!face.enrolled && !protectNotch) || (protectNotch && !authentication.unlocked))
                    .onChange(of: protectNotch) { _, _ in authentication.lock() }
                if protectNotch && !authentication.unlocked {
                    Button("Authenticate to change protection") {
                        authentication.authenticate(reason: "Change notch privacy settings")
                    }.disabled(authentication.phase == .authenticating)
                }
                if protectNotch {
                    Button("Lock now") { authentication.lock() }
                    Text("Scans when you open the notch. Locks again when it closes, the Mac sleeps, or the app restarts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Notch Privacy") } footer: {
                Text("This is 2D face recognition, not Apple’s TrueDepth Face ID. Photo/video resistance is limited. It locks the notch interface, does not encrypt files, and cannot authorize Apple Pay, software installation or Mac login. Mac password / Touch ID remains available for recovery.")
            }
        }
        .sheet(isPresented: $showingEnrollment) { FaceEnrollmentView() }
        .alert("Remove your saved face?", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) { }
            Button("Remove Face", role: .destructive) {
                authorizeManagement {
                    do {
                        try FaceTemplateStore.delete()
                        protectNotch = false
                        authentication.lock()
                        face.refreshEnrollment()
                    } catch { managementError = error.localizedDescription }
                }
            }
        } message: { Text("Your face template will be deleted from this Mac. You can set it up again later.") }
        .onAppear { face.refreshEnrollment() }
        .onDisappear {
            managementContext?.invalidate()
            managementContext = nil
            if face.running { authentication.lock() }
        }
    }

    private func authorizeManagement(action: @escaping @MainActor () -> Void) {
        guard !managementBusy else { return }
        managementBusy = true
        managementError = nil
        let context = LAContext()
        managementContext = context
        Task { @MainActor in
            defer { managementBusy = false; managementContext = nil }
            do {
                let accepted = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                    localizedReason: "Manage the face saved for notch recognition")
                guard accepted, managementContext === context else { return }
                action()
            } catch { managementError = error.localizedDescription }
        }
    }
}
