import AppKit
import SwiftUI



@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, duration: TimeInterval = 2.2) {
        let host = NSHostingView(rootView: ToastView(text: text))
        host.layout()
        let size = host.fittingSize
        let w = max(140, size.width), h = max(34, size.height)

        let p = panel ?? makePanel()
        panel = p
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        p.setContentSize(NSSize(width: w, height: h))
        p.contentView = host

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - w / 2, y: f.maxY - h - 56))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }

        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup(
                { $0.duration = 0.3; p.animator().alphaValue = 0 },
                completionHandler: { p.orderOut(nil) }
            )
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 140, height: 34),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        return p
    }
}

private struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.Palette.hudText)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule(style: .continuous).fill(Theme.Palette.hudBg.opacity(0.96)))
            .overlay(Capsule(style: .continuous).strokeBorder(Theme.Palette.hudBorder, lineWidth: 0.5))
            .fixedSize()
    }
}
