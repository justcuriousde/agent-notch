//
//  MusicVisualizer.swift
//  AgentNotch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//
import AppKit
import Cocoa
import SwiftUI

enum MusicActivityStyle: String, CaseIterable, Identifiable {
    case bars = "Bars"
    case wave = "Wave"
    case dots = "Dancing dots"
    case pulse = "Pulse"
    case random = "Random per song"
    var id: String { rawValue }
}

/// Decorative playback animation. This does not sample or claim to measure audio.
struct MusicActivityAnimation: View {
    let style: String
    let speed: Double
    let isPlaying: Bool
    let trackID: String
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var resolvedStyle: MusicActivityStyle {
        let chosen = MusicActivityStyle(rawValue: style) ?? .bars
        guard chosen == .random else { return chosen }
        let seed = trackID.utf8.reduce(0) { ($0 * 31 + Int($1)) % 65521 }
        return [MusicActivityStyle.bars, .wave, .dots, .pulse][seed % 4]
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying || reduceMotion)) { timeline in
            Canvas { context, size in
                let t = isPlaying && !reduceMotion
                    ? timeline.date.timeIntervalSinceReferenceDate * min(max(speed, 0.5), 2) : 0
                let animated = isPlaying && !reduceMotion
                let mid = CGPoint(x: size.width / 2, y: size.height / 2)
                switch resolvedStyle {
                case .pulse:
                    let beat = animated ? (sin(t * 5) + 1) / 2 : 0.3
                    let radius = min(size.width, size.height) * (0.2 + beat * 0.14)
                    let core = CGRect(x: mid.x - radius, y: mid.y - radius,
                                      width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: core), with: .color(color))
                    let ring = core.insetBy(dx: -3, dy: -3)
                    context.stroke(Path(ellipseIn: ring), with: .color(color.opacity(0.25 + beat * 0.35)), lineWidth: 1)
                case .dots:
                    for index in 0..<3 {
                        let phase = t * 5 + Double(index) * 1.2
                        let y = animated ? sin(phase) * size.height * 0.24 : 0
                        let diameter = min(size.width / 5, 4)
                        let rect = CGRect(x: size.width * CGFloat(index + 1) / 4 - diameter / 2,
                                          y: mid.y + y - diameter / 2, width: diameter, height: diameter)
                        context.fill(Path(ellipseIn: rect), with: .color(color))
                    }
                case .wave:
                    var path = Path()
                    for index in 0...32 {
                        let x = size.width * CGFloat(index) / 32
                        let envelope = sin(Double(index) / 32 * .pi)
                        let y = animated ? sin(Double(index) * 0.36 - t * 6) * size.height * 0.36 * envelope : 0
                        let point = CGPoint(x: x, y: mid.y + y)
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                case .bars, .random:
                    for index in 0..<5 {
                        let phase = Double(index) * 1.7
                        let energy = animated ? 0.25 + 0.75 * abs(sin(t * 3.5 + phase) * cos(t * 1.3 + phase)) : 0.2
                        let height = max(3, size.height * energy)
                        let width = size.width / 9
                        let rect = CGRect(x: CGFloat(index) * size.width / 5 + width / 2,
                                          y: mid.y - height / 2, width: width, height: height)
                        context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(color))
                    }
                }
            }
        }
        .accessibilityLabel("Decorative music animation: \(resolvedStyle.rawValue)")
    }
}

class AudioSpectrum: NSView {
    private var barLayers: [CAShapeLayer] = []
    private var barScales: [CGFloat] = []
    private var isPlaying: Bool = true
    private var animationTimer: Timer?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    private func setupBars() {
        let barWidth: CGFloat = 2
        let barCount = 4
        let spacing: CGFloat = barWidth
        let totalWidth = CGFloat(barCount) * (barWidth + spacing)
        let totalHeight: CGFloat = 14
        frame.size = CGSize(width: totalWidth, height: totalHeight)

        for i in 0 ..< barCount {
            let xPosition = CGFloat(i) * (barWidth + spacing)
            let barLayer = CAShapeLayer()
            barLayer.frame = CGRect(x: xPosition, y: 0, width: barWidth, height: totalHeight)
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            barLayer.position = CGPoint(x: xPosition + barWidth / 2, y: totalHeight / 2)
            barLayer.fillColor = NSColor.white.cgColor
            barLayer.backgroundColor = NSColor.white.cgColor
            barLayer.allowsGroupOpacity = false
            barLayer.masksToBounds = true
            let path = NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: barWidth, height: totalHeight),
                                    xRadius: barWidth / 2,
                                    yRadius: barWidth / 2)
            barLayer.path = path.cgPath
            barLayers.append(barLayer)
            barScales.append(0.35)
            layer?.addSublayer(barLayer)
        }
    }
    
    private func startAnimating() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.updateBars()
        }
    }
    
    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        resetBars()
    }
    
    private func updateBars() {
        for (i, barLayer) in barLayers.enumerated() {
            let currentScale = barScales[i]
            let targetScale = CGFloat.random(in: 0.35 ... 1.0)
            barScales[i] = targetScale
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = currentScale
            animation.toValue = targetScale
            animation.duration = 0.3
            animation.autoreverses = true
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            if #available(macOS 13.0, *) {
                animation.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 24, preferred: 24)
            }
            barLayer.add(animation, forKey: "scaleY")
        }
    }
    
    private func resetBars() {
        for (i, barLayer) in barLayers.enumerated() {
            barLayer.removeAllAnimations()
            barLayer.transform = CATransform3DMakeScale(1, 0.35, 1)
            barScales[i] = 0.35
        }
    }
    
    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        if isPlaying {
            startAnimating()
        } else {
            stopAnimating()
        }
    }
}

struct AudioSpectrumView: NSViewRepresentable {
    @Binding var isPlaying: Bool
    
    func makeNSView(context: Context) -> AudioSpectrum {
        let spectrum = AudioSpectrum()
        spectrum.setPlaying(isPlaying)
        return spectrum
    }
    
    func updateNSView(_ nsView: AudioSpectrum, context: Context) {
        nsView.setPlaying(isPlaying)
    }
}

#Preview {
    AudioSpectrumView(isPlaying: .constant(true))
        .frame(width: 16, height: 20)
        .padding()
}
