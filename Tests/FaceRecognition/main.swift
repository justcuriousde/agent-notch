import Foundation
import CoreML
import Vision
import CoreImage

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

// The live camera manager is not started by this harness.
@MainActor final class WebcamManager {
    static let shared = WebcamManager()
    func stopSession() { }
}

let basis = [Float(1)] + [Float](repeating: 0, count: 511)
let other = [Float(0), 1] + [Float](repeating: 0, count: 510)
expect(FaceIdentityMath.normalize([Float](repeating: 0, count: 512)) == nil, "Zero vector must fail")
expect(FaceIdentityMath.normalize([Float.nan] + basis.dropFirst()) == nil, "NaN must fail")
let identity = FaceIdentity(version: FaceIdentity.modelVersion, createdAt: Date(), vectors: Array(repeating: basis, count: 18))
expect(identity.isValid, "Template validation")
expect(FaceIdentityMath.matches(basis, identity: identity), "Same identity must match")
expect(!FaceIdentityMath.matches(other, identity: identity), "Different identity must fail")
expect(!FaceIdentityMath.matches(basis, identity: FaceIdentity(version: "old", createdAt: Date(), vectors: identity.vectors)), "Old model must fail")
let oneBad = FaceIdentity(version: FaceIdentity.modelVersion, createdAt: Date(), vectors: [basis] + Array(repeating: other, count: 17))
expect(!FaceIdentityMath.matches(basis, identity: oneBad), "One similar sample is insufficient")

var still = FaceMotionChallenge(actions: [.left, .blink, .right])
for i in 0..<300 { _ = still.observe(yaw: 0, eyeRatio: 0.3, time: Double(i) * 0.15) }
expect(!still.complete && still.current == .left, "A static face cannot pass the motion challenge")

var challenge = FaceMotionChallenge(actions: [.left, .blink, .right])
var clock = 0.0
func frames(_ yaw: Double, _ eyeRatio: Double, count: Int = 12) {
    for _ in 0..<count {
        clock += 0.15
        _ = challenge.observe(yaw: yaw, eyeRatio: eyeRatio, time: clock)
    }
}
frames(0, 0.3)
expect(challenge.current == .left, "Center must advance to left turn")
frames(0.3, 0.3)
expect(challenge.current == .left, "Wrong turn must not advance")
frames(-0.3, 0.3)
frames(0, 0.3)
expect(challenge.current == .blink, "Turn and recenter before blink")
frames(0, 0.3)
expect(challenge.current == .blink, "Open eyes cannot complete blink")
frames(0, 0.08, count: 2)
frames(0, 0.3)
expect(challenge.current == .right, "Closed then open eyes complete blink and recenter")
frames(0.3, 0.3)
frames(0, 0.3)
expect(challenge.complete, "Full fresh challenge must pass")

let source = [CGPoint(x: 1,y: 2), CGPoint(x: 3,y: 2), CGPoint(x: 2,y: 4)]
let expectedTransform = CGAffineTransform(a: 2, b: 0.4, c: -0.4, d: 2, tx: 10, ty: -5)
let destination = source.map { $0.applying(expectedTransform) }
let actual = try FaceEmbeddingExtractor.similarityTransform(source, destination)
for (src, dst) in zip(source, destination) {
    let p = src.applying(actual)
    expect(hypot(p.x - dst.x, p.y - dst.y) < 0.0001, "Alignment must preserve scale, rotation and translation")
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let extractor = try FaceEmbeddingExtractor(modelURL: root.appendingPathComponent("AgentNotch/Resources/EdgeFace_XS.mlmodelc"))
var buffer: CVPixelBuffer?
CVPixelBufferCreate(kCFAllocatorDefault, 112, 112, kCVPixelFormatType_32BGRA,
    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
let ci = CIContext()
let image = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6)).cropped(to: CGRect(x: 0,y: 0,width: 112,height: 112))
ci.render(image, to: buffer!)
let vector = try extractor.embedding(buffer!)
expect(vector.count == 512 && vector.allSatisfy(\.isFinite), "Bundled model must execute on this Mac")
print("PASS: matching validation, motion challenge, alignment and actual Core ML inference")

if CommandLine.arguments.count == 4 {
    func embeddingForImage(_ path: String) throws -> [Float] {
        let url = URL(fileURLWithPath: path)
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(url: url).perform([request])
        guard let faces = request.results, faces.count == 1, let face = faces.first,
              let image = CIImage(contentsOf: url) else { fatalError("Test image must contain exactly one face") }
        return try extractor.embedding(extractor.alignedBuffer(image: image, face: face))
    }
    let first = try embeddingForImage(CommandLine.arguments[1])
    let same = try embeddingForImage(CommandLine.arguments[2])
    let different = try embeddingForImage(CommandLine.arguments[3])
    let sameScore = FaceIdentityMath.cosine(first, same)
    let differentScore = FaceIdentityMath.cosine(first, different)
    print("Fixture scores — same person: \(sameScore); different person: \(differentScore)")
    expect(sameScore >= 0.65, "Same-person fixture must match")
    expect(differentScore < 0.65, "Different-person fixture must not match")
    print("PASS: distinct real-photo fixtures")
}
