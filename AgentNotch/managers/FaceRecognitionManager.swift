import AVFoundation
import Vision
import CoreML
import CoreImage
import Security
import SwiftUI

struct FaceTemplateStore {
    private static let service = "app.agentnotch.face-template.v1"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "owner",
         kSecAttrSynchronizable as String: false]
    }
    static func load() throws -> FaceIdentity? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw FaceScanError.message("Cannot read the saved face from Keychain (\(status)).")
        }
        let identity = try JSONDecoder().decode(FaceIdentity.self, from: data)
        guard identity.isValid else { throw FaceScanError.message("The saved face is incompatible. Set up your face again using your Mac password.") }
        return identity
    }
    static func save(_ identity: FaceIdentity) throws {
        guard identity.isValid else { throw FaceScanError.message("Face scan was incomplete. Nothing was saved.") }
        let data = try JSONEncoder().encode(identity)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw FaceScanError.message("Could not save your face to Keychain (\(status)).") }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FaceScanError.message("Could not remove the saved face (\(status)).")
        }
    }
}

enum FaceScanError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// All capture, Vision, inference and challenge state belongs to this serial queue.
final class FaceCaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.agentnotch.face-capture", qos: .userInitiated)
    private var extractor: FaceEmbeddingExtractor?
    private var runID: UUID?
    private let cancellationLock = NSLock()
    private var requestedRun: UUID?
    private var enrolling = false
    private var identity: FaceIdentity?
    private var challenge = FaceMotionChallenge()
    private var anchor: [Float]?
    private var samples: [[Float]] = []
    private var recent: [[Float]] = []
    private var lastFrame: TimeInterval = 0
    private var lastValid: TimeInterval = 0
    private var update: (@Sendable (String, Double) -> Void)?
    private var completion: (@Sendable (Result<Bool, Error>) -> Void)?

    func start(enrolling: Bool, update: @escaping @Sendable (String, Double) -> Void,
               completion: @escaping @Sendable (Result<Bool, Error>) -> Void) {
        let token = UUID()
        cancellationLock.withLock { requestedRun = token }
        queue.async {
            guard self.isRequested(token) else { return }
            self.stopOnQueue()
            self.runID = token
            self.enrolling = enrolling
            self.update = update
            self.completion = completion
            self.resetChallenge()
            self.lastFrame = 0
            do {
                self.identity = enrolling ? nil : try FaceTemplateStore.load()
                guard enrolling || self.identity != nil else { throw FaceScanError.message("Set up your face in Settings → Face ID first.") }
                if self.extractor == nil { self.extractor = try FaceEmbeddingExtractor() }
                guard let device = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                      mediaType: .video, position: .unspecified).devices.first else {
                    throw FaceScanError.message("A built-in camera is required. Use your Mac password on this device.")
                }
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.setSampleBufferDelegate(self, queue: self.queue)
                guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                    throw FaceScanError.message("The camera is busy or unavailable.")
                }
                self.session.beginConfiguration()
                self.session.sessionPreset = .vga640x480
                self.session.addInput(input)
                self.session.addOutput(output)
                if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
                self.session.commitConfiguration()
                self.update?("Position your face inside the circle", 0)
                self.session.startRunning()
                self.queue.asyncAfter(deadline: .now() + 45) {
                    guard self.runID == token else { return }
                    self.finish(.failure(FaceScanError.message("Scan timed out. Improve the lighting and try again.")))
                }
            } catch { self.finish(.failure(error)) }
        }
    }

    func stop() {
        cancellationLock.withLock { requestedRun = nil }
        queue.async { self.stopOnQueue() }
    }

    private func isRequested(_ token: UUID) -> Bool {
        cancellationLock.withLock { requestedRun == token }
    }

    private func stopOnQueue() {
        runID = nil
        completion = nil
        update = nil
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for output in session.outputs {
            (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            session.removeOutput(output)
        }
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()
        identity = nil
        anchor = nil
        samples.removeAll()
        recent.removeAll()
    }

    private func finish(_ result: Result<Bool, Error>) {
        let callback = completion
        stopOnQueue()
        callback?(result)
    }

    private func resetChallenge() {
        challenge = FaceMotionChallenge()
        anchor = nil
        samples.removeAll()
        recent.removeAll()
        lastValid = 0
    }

    private func invalid(_ instruction: String, at time: TimeInterval) {
        if lastValid > 0 && time - lastValid > 0.8 { resetChallenge() }
        update?(instruction, challenge.progress)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let token = runID, isRequested(token), let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastFrame > 0.10 else { return }
        lastFrame = now
        autoreleasepool {
            do {
                let request = VNDetectFaceLandmarksRequest()
                try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
                guard let faces = request.results, faces.count == 1, let face = faces.first else {
                    // Never continue a partial challenge across an extra face entering the frame.
                    if (request.results?.count ?? 0) > 1 { resetChallenge() }
                    invalid("Only your face should be visible", at: now)
                    return
                }
                let box = face.boundingBox
                guard box.width > 0.18, box.height > 0.25, box.minX > 0.03, box.maxX < 0.97,
                      box.minY > 0.03, box.maxY < 0.97, abs(face.roll?.doubleValue ?? 1) < 0.20,
                      let yaw = face.yaw?.doubleValue, let landmarks = face.landmarks else {
                    invalid("Center your face, move closer, and keep your head upright", at: now)
                    return
                }
                let image = CIImage(cvPixelBuffer: buffer)
                guard let extractor else { throw FaceScanError.message("Face recognition is unavailable") }
                let aligned = try extractor.alignedBuffer(image: image, face: face)
                let vector = try extractor.embedding(aligned)
                if let identity, !FaceIdentityMath.matches(vector, identity: identity) {
                    resetChallenge()
                    update?("Face not recognized. Use your enrolled face or Mac password.", 0)
                    return
                }
                if let anchor, FaceIdentityMath.cosine(vector, anchor) < 0.60 {
                    resetChallenge()
                    update?("Face changed. Start again with one person.", 0)
                    return
                }
                let ratio = try eyeRatio(landmarks, box: box, size: image.extent.size)
                lastValid = now
                if anchor == nil {
                    guard abs(yaw) < 0.16, ratio > 0.16 else { update?("Look straight at the camera with your eyes open", 0); return }
                    anchor = vector
                }
                recent.append(vector)
                if recent.count > 3 { recent.removeFirst() }
                let oldStep = challenge.current
                if challenge.observe(yaw: yaw, eyeRatio: ratio, time: now), oldStep != .blink {
                    samples.append(contentsOf: recent)
                    recent.removeAll()
                }
                update?(challenge.instruction, challenge.progress)
                if challenge.complete {
                    guard isRequested(token) else { return }
                    if enrolling {
                        let saved = FaceIdentity(version: FaceIdentity.modelVersion, createdAt: Date(), vectors: samples)
                        do { try FaceTemplateStore.save(saved) }
                        catch { finish(.failure(error)); return }
                    }
                    finish(.success(enrolling))
                }
            } catch {
                // Missing/occluded landmarks are recoverable; inference failures fail closed.
                if let scanError = error as? FaceScanError {
                    invalid(scanError.localizedDescription, at: now)
                } else { finish(.failure(error)) }
            }
        }
    }

    private func eyeRatio(_ landmarks: VNFaceLandmarks2D, box: CGRect, size: CGSize) throws -> Double {
        func aspect(_ region: VNFaceLandmarkRegion2D?) -> Double? {
            guard let points = region?.normalizedPoints, points.count >= 6 else { return nil }
            let xs = points.map(\.x), ys = points.map(\.y)
            let width = Double((xs.max()! - xs.min()!) * box.width * size.width)
            let height = Double((ys.max()! - ys.min()!) * box.height * size.height)
            return width > 1 ? height / width : nil
        }
        guard let left = aspect(landmarks.leftEye), let right = aspect(landmarks.rightEye) else {
            throw FaceScanError.message("Keep both eyes visible")
        }
        return (left + right) / 2
    }

}

/// Aligned 112×112 RGB input; the bundled Core ML model owns [-1, 1] normalization.
final class FaceEmbeddingExtractor {
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let model: MLModel
    private let outputName: String

    init(modelURL: URL? = nil) throws {
        guard let url = modelURL ?? Bundle.main.url(forResource: "EdgeFace_XS", withExtension: "mlmodelc") else {
            throw FaceScanError.message("Face recognition model is missing. Reinstall AgentNotch.")
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: url, configuration: config)
        guard let name = model.modelDescription.outputDescriptionsByName.first?.key else {
            throw FaceScanError.message("The face model has no embedding output")
        }
        outputName = name
    }

    func embedding(_ buffer: CVPixelBuffer) throws -> [Float] {
        let input = try MLDictionaryFeatureProvider(dictionary: ["faceImage": MLFeatureValue(pixelBuffer: buffer)])
        let prediction = try model.prediction(from: input)
        guard let array = prediction.featureValue(for: outputName)?.multiArrayValue, array.count == 512,
              let vector = FaceIdentityMath.normalize((0..<array.count).map { array[$0].floatValue }) else {
            throw FaceScanError.message("Could not read facial features. Try again.")
        }
        return vector
    }

    func alignedBuffer(image: CIImage, face: VNFaceObservation) throws -> CVPixelBuffer {
        guard let landmarks = face.landmarks,
              let left = landmarks.leftEye, let right = landmarks.rightEye,
              let nose = landmarks.nose, let lips = landmarks.outerLips else {
            throw FaceScanError.message("Keep your eyes, nose and mouth visible")
        }
        let box = face.boundingBox
        func absolute(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (box.minX + point.x * box.width) * image.extent.width,
                    y: (box.minY + point.y * box.height) * image.extent.height)
        }
        func center(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
            let points = region.normalizedPoints
            return absolute(CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                                    y: points.map(\.y).reduce(0, +) / CGFloat(points.count)))
        }
        let eyes = [center(left), center(right)].sorted { $0.x < $1.x }
        let mouth = lips.normalizedPoints.sorted { $0.x < $1.x }
        guard let first = mouth.first, let last = mouth.last else { throw FaceScanError.message("Keep your mouth visible") }
        let source = [eyes[0], eyes[1], center(nose), absolute(first), absolute(last)]
        // Canonical ArcFace coordinates converted to Core Image's bottom-left origin.
        let target = [CGPoint(x: 38.2946, y: 112 - 51.6963), CGPoint(x: 73.5318, y: 112 - 51.5014),
                      CGPoint(x: 56.0252, y: 112 - 71.7366), CGPoint(x: 41.5493, y: 112 - 92.3655),
                      CGPoint(x: 70.7299, y: 112 - 92.2041)]
        let transform = try Self.similarityTransform(source, target)
        let aligned = image.transformed(by: transform).cropped(to: CGRect(x: 0, y: 0, width: 112, height: 112))
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 112, 112, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
             kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else { throw FaceScanError.message("Could not prepare the camera frame") }
        ci.render(aligned, to: pixelBuffer, bounds: CGRect(x: 0, y: 0, width: 112, height: 112), colorSpace: CGColorSpaceCreateDeviceRGB())
        return pixelBuffer
    }

    static func similarityTransform(_ source: [CGPoint], _ target: [CGPoint]) throws -> CGAffineTransform {
        guard source.count == target.count, source.count >= 2 else { throw FaceScanError.message("Face alignment failed") }
        let n = CGFloat(source.count)
        let srcMean = CGPoint(x: source.map(\.x).reduce(0, +) / n, y: source.map(\.y).reduce(0, +) / n)
        let dstMean = CGPoint(x: target.map(\.x).reduce(0, +) / n, y: target.map(\.y).reduce(0, +) / n)
        var denominator: CGFloat = 0, real: CGFloat = 0, imaginary: CGFloat = 0
        for (s, d) in zip(source, target) {
            let x = s.x - srcMean.x, y = s.y - srcMean.y
            let u = d.x - dstMean.x, v = d.y - dstMean.y
            denominator += x*x + y*y
            real += x*u + y*v
            imaginary += x*v - y*u
        }
        guard denominator > 0.001 else { throw FaceScanError.message("Move closer to the camera") }
        let a = real / denominator, b = imaginary / denominator
        return CGAffineTransform(a: a, b: b, c: -b, d: a,
            tx: dstMean.x - a*srcMean.x + b*srcMean.y, ty: dstMean.y - b*srcMean.x - a*srcMean.y)
    }
}

@MainActor
final class FaceRecognitionManager: ObservableObject {
    static let shared = FaceRecognitionManager()
    @Published private(set) var running = false
    @Published private(set) var enrolled = false
    @Published private(set) var message = "Set up your face to unlock with the camera"
    @Published private(set) var progress = 0.0
    @Published private(set) var succeeded = false
    let engine = FaceCaptureEngine()
    private var token = UUID()
    private var completion: ((Bool) -> Void)?
    private var failedAttempts = 0
    private var retryAfter = Date.distantPast

    private init() { refreshEnrollment() }
    func refreshEnrollment() {
        do { enrolled = try FaceTemplateStore.load() != nil }
        catch { enrolled = false; message = error.localizedDescription }
    }
    func cancel() {
        token = UUID()
        engine.stop()
        running = false
        succeeded = false
        progress = 0
        completion = nil
    }
    func begin(enrolling: Bool, completion: @escaping (Bool) -> Void) {
        guard !running else { completion(false); return }
        guard enrolling || Date() >= retryAfter else { message = "Too many attempts. Wait 30 seconds or use your Mac password."; completion(false); return }
        cancel()
        succeeded = false
        running = true
        message = "Preparing the camera…"
        self.completion = completion
        let attempt = UUID()
        token = attempt
        Task {
            let authorized: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: authorized = true
            case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
            default: authorized = false
            }
            guard token == attempt else { return }
            guard authorized else {
                running = false
                message = "Allow Camera access for AgentNotch in System Settings → Privacy & Security → Camera."
                self.completion = nil
                completion(false)
                return
            }
            WebcamManager.shared.stopSession()
            self.engine.start(enrolling: enrolling, update: { [weak self] text, fraction in
                Task { @MainActor in
                    guard let self, self.token == attempt else { return }
                    self.message = text
                    self.progress = fraction
                }
            }, completion: { [weak self] result in
                Task { @MainActor in
                    guard let self, self.token == attempt else { return }
                    self.running = false
                    let passed: Bool
                    switch result {
                    case .success:
                        passed = true
                        self.succeeded = true
                        self.failedAttempts = 0
                        self.progress = 1
                        self.message = enrolling ? "Your face is saved on this Mac" : "Face recognized"
                        self.refreshEnrollment()
                    case .failure(let error):
                        passed = false
                        self.message = error.localizedDescription
                        self.failedAttempts += 1
                        if self.failedAttempts >= 5 { self.retryAfter = Date().addingTimeInterval(30); self.failedAttempts = 0 }
                    }
                    let callback = self.completion
                    self.completion = nil
                    callback?(passed)
                }
            })
        }
    }
}
