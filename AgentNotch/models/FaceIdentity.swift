import Foundation

/// Versioned, device-local embeddings. Raw frames are never persisted.
struct FaceIdentity: Codable {
    static let modelVersion = "edgeface-xs-c295e5ca-v1"
    let version: String
    let createdAt: Date
    let vectors: [[Float]]

    var isValid: Bool {
        version == Self.modelVersion && (12...30).contains(vectors.count)
            && vectors.allSatisfy { vector in
                vector.count == 512 && vector.allSatisfy(\.isFinite)
                    && abs(vector.reduce(Float(0)) { $0 + $1 * $1 } - 1) < 0.02
            }
    }
}

enum FaceIdentityMath {
    static func normalize(_ vector: [Float]) -> [Float]? {
        guard vector.count == 512, vector.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0.00001 else { return nil }
        return vector.map { $0 / norm }
    }

    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == 512, rhs.count == 512,
              lhs.allSatisfy(\.isFinite), rhs.allSatisfy(\.isFinite) else { return -1 }
        return zip(lhs, rhs).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    }

    /// Multiple enrollment poses must agree; a single accidentally similar sample is insufficient.
    static func matches(_ vector: [Float], identity: FaceIdentity) -> Bool {
        guard identity.isValid else { return false }
        let scores = identity.vectors.map { cosine(vector, $0) }.sorted(by: >)
        return scores.prefix(3).count == 3 && scores[2] >= 0.65
    }
}

/// RGB motion challenge, not a depth-based presentation-attack detector.
struct FaceMotionChallenge {
    enum Step: Equatable { case center, left, right, blink }
    private(set) var steps: [Step]
    private(set) var index = 0
    private var stableFrames = 0
    private var openEyeRatio: Double = 0
    private var blinkClosed = false
    private var blinkStartedAt: TimeInterval?
    private var stepStartedAt: TimeInterval?

    init(actions: [Step] = [.left, .right, .blink].shuffled()) {
        steps = [.center]
        for action in actions { steps.append(action); steps.append(.center) }
    }

    var complete: Bool { index == steps.count }
    var current: Step? { complete ? nil : steps[index] }
    var progress: Double { Double(index) / Double(steps.count) }
    var instruction: String {
        switch current {
        case .center: return "Look straight at the camera and hold still"
        case .left: return "Slowly turn your face toward the left arrow ←"
        case .right: return "Slowly turn your face toward the right arrow →"
        case .blink: return blinkClosed ? "Open your eyes again" : "Blink slowly once"
        case nil: return "Scan complete"
        }
    }

    /// Returns true only on the frame that completes a step.
    mutating func observe(yaw: Double, eyeRatio: Double, time: TimeInterval) -> Bool {
        guard let current, yaw.isFinite, eyeRatio.isFinite else { return false }
        if stepStartedAt == nil { stepStartedAt = time }
        guard time - (stepStartedAt ?? time) >= 0.35 else { return false }
        var accepted = false
        switch current {
        case .center:
            accepted = abs(yaw) < 0.16 && eyeRatio > 0.16
            if accepted { openEyeRatio = max(openEyeRatio, eyeRatio) }
        case .left:
            accepted = yaw < -0.23 && yaw > -0.58
        case .right:
            accepted = yaw > 0.23 && yaw < 0.58
        case .blink:
            guard abs(yaw) < 0.16, openEyeRatio > 0.16 else { return false }
            if eyeRatio < openEyeRatio * 0.55 && !blinkClosed {
                blinkClosed = true
                blinkStartedAt = time
            }
            if blinkClosed, let began = blinkStartedAt, time - began > 1.8 {
                blinkClosed = false
                blinkStartedAt = nil
            }
            accepted = blinkClosed && eyeRatio > openEyeRatio * 0.8
        }
        stableFrames = accepted ? stableFrames + 1 : 0
        let required = current == .blink ? 1 : 3
        guard stableFrames >= required else { return false }
        index += 1
        stableFrames = 0
        stepStartedAt = nil
        blinkClosed = false
        blinkStartedAt = nil
        return true
    }
}
