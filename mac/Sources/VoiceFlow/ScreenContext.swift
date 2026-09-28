import AppKit
import ApplicationServices











@MainActor
enum ScreenContext {




    private static let systemWide: AXUIElement = {
        let el = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(el, 0.15)
        return el
    }()


    private static let window = 700

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }


    static func aroundCursor() -> String? {
        guard let f = attr(systemWide, kAXFocusedUIElementAttribute as String) else { return nil }
        let el = f as! AXUIElement
        guard let text = attr(el, kAXValueAttribute as String) as? String, !text.isEmpty else { return nil }

        let chars = Array(text)

        var caret = chars.count
        if let r = attr(el, kAXSelectedTextRangeAttribute as String) {
            var range = CFRange()
            if AXValueGetValue(r as! AXValue, .cfRange, &range) {
                caret = min(max(range.location, 0), chars.count)
            }
        }
        let lo = max(0, caret - window)
        let hi = min(chars.count, caret + window)
        guard lo < hi else { return nil }
        return String(chars[lo..<hi])
    }
}
