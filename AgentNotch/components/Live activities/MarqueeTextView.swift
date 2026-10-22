//
//  MarqueeTextView.swift
//  AgentNotch
//
//  Created by Richard Kunkli on 08/08/2024.
//

import SwiftUI

struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct MeasureSizeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(GeometryReader { geometry in
            Color.clear.preference(key: SizePreferenceKey.self, value: geometry.size)
        })
    }
}

struct MarqueeText: View {
    @Binding var text: String
    let font: Font
    let nsFont: NSFont.TextStyle
    let textColor: Color
    let backgroundColor: Color
    let minDuration: Double
    let frameWidth: CGFloat
    let lineHeight: CGFloat?
    
    @State private var animate = false
    @State private var textSize: CGSize = .zero
    @State private var offset: CGFloat = 0
    
    init(_ text: Binding<String>, font: Font = .body, nsFont: NSFont.TextStyle = .body, textColor: Color = .primary, backgroundColor: Color = .clear, minDuration: Double = 3.0, frameWidth: CGFloat = 200, lineHeight: CGFloat? = nil) {
        _text = text
        self.font = font
        self.nsFont = nsFont
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.minDuration = minDuration
        self.frameWidth = frameWidth
        self.lineHeight = lineHeight
    }
    
    private var needsScrolling: Bool {
        frameWidth > 0 && textSize.width > frameWidth + 1
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                HStack(spacing: 20) {
                    Text(text)
                        .fixedSize(horizontal: true, vertical: false)
                        .modifier(MeasureSizeModifier())
                    if needsScrolling {
                        Text(text)
                    }
                }
                .id(text)
                .font(font)
                .foregroundColor(textColor)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: self.animate ? offset : 0)
                .animation(
                    self.animate ?
                        .linear(duration: Double(textSize.width / 30))
                        .delay(minDuration)
                        .repeatForever(autoreverses: false) : .none,
                    value: self.animate
                )
                .background(backgroundColor)
                .onPreferenceChange(SizePreferenceKey.self) { size in
                    self.textSize = size
                }
                .task(id: "\(text)|\(frameWidth)|\(textSize.width)") {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        animate = false
                        offset = 0
                    }
                    guard needsScrolling else { return }
                    do {
                        try await Task.sleep(for: .milliseconds(100))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    offset = -(textSize.width + 20)
                    animate = true
                }
            }
            .frame(width: frameWidth, alignment: .leading)
            .clipped()
        }
        .frame(height: lineHeight ?? textSize.height * 1.3)
        
    }
}
