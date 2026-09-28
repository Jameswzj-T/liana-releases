import AppKit
import ApplicationServices







@MainActor
enum AXProbe {
    private static let systemWide = AXUIElementCreateSystemWide()
    private static var timer: Timer?
    private static var observer: AXObserver?
    private static var lastKey = ""
    private static var lastValue: String?

    static func start() {
        print("""

        === [AXProbe] 应用内诊断已启动 ===
        把光标点进 微信 / 备忘录 / 浏览器 / 飞书 的输入框,打几个字、再改几个字。
        看下面三项(尤其微信):值可读 ✅/❌ · ✏️ 轮询见变化 · 🔔 push 即时通知。

        """)
        let t = Timer(timeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated { poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func copyAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private static func short(_ s: String) -> String {
        s.count > 60 ? String(s.prefix(60)) + "…" : s
    }

    private static func poll() {
        guard let v = copyAttr(systemWide, kAXFocusedUIElementAttribute as String) else {
            if lastKey != "none" {
                print("[AXProbe] · 当前无可读焦点元素")
                lastKey = "none"; lastValue = nil
            }
            return
        }
        let el = v as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        let role = (copyAttr(el, kAXRoleAttribute as String) as? String) ?? "?"
        let sub = copyAttr(el, kAXSubroleAttribute as String) as? String
        let val = copyAttr(el, kAXValueAttribute as String) as? String
        let key = "\(pid)|\(role)|\(sub ?? "")"

        if key != lastKey {
            print("\n[AXProbe] ──────")
            print("[AXProbe] 焦点:[\(app)] role=\(role)\(sub.map { " / \($0)" } ?? "")")
            print("[AXProbe]   值可读 = \(val != nil ? "✅ 能读到文本" : "❌ 读不到(此 app 不暴露内容)")")
            if let s = val { print("[AXProbe]   当前内容:「\(short(s))」") }
            lastKey = key; lastValue = val
            attachObserver(el, pid)
        } else if val != lastValue {
            print("[AXProbe]   ✏️ 轮询看到内容变化 ✅ →「\(short(val ?? ""))」")
            lastValue = val
        }
    }

    private static func attachObserver(_ el: AXUIElement, _ pid: pid_t) {
        if let old = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
            observer = nil
        }
        var obs: AXObserver?
        guard AXObserverCreate(pid, axProbeCallback, &obs) == .success, let o = obs else {
            print("[AXProbe]   ⚠️ push 监听创建失败 → 只能轮询")
            return
        }
        if AXObserverAddNotification(o, el, kAXValueChangedNotification as CFString, nil) == .success {
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
            observer = o
            print("[AXProbe]   ✅ push 监听已挂上 → 改字时若冒 🔔 即即时可用")
        } else {
            print("[AXProbe]   ⚠️ push 监听挂不上 → 只能轮询(看 ✏️)")
        }
    }
}


private func axProbeCallback(_ observer: AXObserver, _ element: AXUIElement,
                             _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    print("[AXProbe]   🔔 收到 push 通知「\(notification as String)」→ 即时监听可用 ✅")
}
