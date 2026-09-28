import SwiftUI

extension Color {

    init(hex: UInt, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}



enum Theme {

    enum Palette {
        static let bgBase        = Color(hex: 0xF5F1E8)   // 暖纸底:页面/窗口/悬浮条
        static let bgSurface     = Color(hex: 0xFCFAF4)   // 卡片/面板
        static let bgElevated    = Color(hex: 0xECE6D8)   // pill/hover
        static let borderSubtle  = Color(hex: 0xE2DBCB)   // 描边 1px
        static let textPrimary   = Color(hex: 0x2E2A22)
        static let textSecondary = Color(hex: 0x6F6A5C)
        static let textTertiary  = Color(hex: 0xA39C8A)   // 提示/占位/meta
        static let accent        = Color(hex: 0x3FA35D)   // 草木绿·签名/主操作
        static let accentInk     = Color.white            // 叠在 accent(绿)上的文字/图标
        static let warning       = Color(hex: 0xB8872C)   // 可预览但需人工核对的语义变化
        static let danger        = Color(hex: 0xD06A4F)   // 仅破坏性操作

        static let spectrum: [Color] = [
            Color(hex: 0x5FB83C), Color(hex: 0x14B8C4), Color(hex: 0x3B6FE0),
            Color(hex: 0x8B43D9), Color(hex: 0xE83A82), Color(hex: 0xF0741A), Color(hex: 0xE0A400),
        ]



        static let hudBg       = Color(hex: 0x242220)
        static let hudElevated = Color(hex: 0x34322B)
        static let hudBorder   = Color(hex: 0x48443C)
        static let hudText     = Color(hex: 0xD6D2C6)
    }

    enum Radius {
        static let control: CGFloat = 10
        static let card: CGFloat = 14
        static let hud: CGFloat = 14
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }
}


struct FlowLayout: Layout {
    var spacing: CGFloat = 9

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
