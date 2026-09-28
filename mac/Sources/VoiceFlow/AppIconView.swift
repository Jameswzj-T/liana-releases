import AppKit
import SwiftUI




struct AppIconView: View {
    enum Variant { case green, dark, cream }
    var variant: Variant = .dark
    var side: CGFloat = 512

    private var corner: CGFloat { side * 0.2237 }   // 近似 Apple squircle 圆角比例



    private var inset: CGFloat { side * 0.08 }
    private var art: CGFloat { side - inset * 2 }


    private let heights: [CGFloat] = [0.28, 0.50, 0.74, 1.0, 0.64, 0.42, 0.24]

    var body: some View {
        ZStack {
            squircle
            bars
        }
        .frame(width: side, height: side)
    }

    private var squircle: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return shape
            .fill(bgGradient)
            .overlay(shape.fill(LinearGradient(   // 顶部一抹高光,做出微立体
                colors: [.white.opacity(variant == .cream ? 0.0 : 0.14), .clear],
                startPoint: .top, endPoint: .center)))
            .overlay(shape.strokeBorder(.white.opacity(variant == .cream ? 0.06 : 0.10), lineWidth: side * 0.006))
            .frame(width: art, height: art)
    }

    private var bgGradient: LinearGradient {
        switch variant {
        case .green: return LinearGradient(colors: [Color(hex: 0x49B368), Color(hex: 0x2F8A4C)], startPoint: .top, endPoint: .bottom)
        case .dark:  return LinearGradient(colors: [Color(hex: 0x26262C), Color(hex: 0x141417)], startPoint: .top, endPoint: .bottom)
        case .cream: return LinearGradient(colors: [Color(hex: 0xFCFAF4), Color(hex: 0xEDE7D8)], startPoint: .top, endPoint: .bottom)
        }
    }

    private var bars: some View {
        let n = heights.count
        let gap = art * 0.035
        let barW = (art * 0.66 - gap * CGFloat(n - 1)) / CGFloat(n)
        let maxH = art * 0.50
        return HStack(alignment: .center, spacing: gap) {
            ForEach(0..<n, id: \.self) { i in
                Capsule().fill(barColor(i))
                    .frame(width: barW, height: max(barW, maxH * heights[i]))
            }
        }
    }

    private func barColor(_ i: Int) -> Color {
        switch variant {
        case .green: return Theme.Palette.bgBase                                        // 奶油白波形
        case .dark:  return Theme.Palette.spectrum[i % Theme.Palette.spectrum.count]     // 七彩光谱
        case .cream: return Theme.Palette.spectrum[i % Theme.Palette.spectrum.count]     // 奶油底 + 光谱
        }
    }


    @MainActor
    static func dockImage(variant: Variant = .cream, side: CGFloat = 512) -> NSImage? {
        let renderer = ImageRenderer(content: AppIconView(variant: variant, side: side))
        renderer.scale = 2.0
        return renderer.nsImage
    }
}
