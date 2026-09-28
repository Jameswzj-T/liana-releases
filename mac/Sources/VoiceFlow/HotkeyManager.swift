import AppKit



@MainActor
final class HotkeyManager {
    private let onTrigger: @MainActor () -> Void
    private var config = HotkeyConfig.current
    private var globalMon: Any?
    private var localMon: Any?

    init(onTrigger: @escaping @MainActor () -> Void) {
        self.onTrigger = onTrigger
    }

    func apply(_ cfg: HotkeyConfig) {
        config = cfg
        stop()
        let mask: NSEvent.EventTypeMask = cfg.isModifierOnly ? .flagsChanged : .keyDown
        globalMon = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }
        localMon = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }
        vlog("热键已应用: \(cfg.prettyDisplay)  modifierOnly=\(cfg.isModifierOnly)")
    }

    func stop() {
        if let m = globalMon { NSEvent.removeMonitor(m); globalMon = nil }
        if let m = localMon { NSEvent.removeMonitor(m); localMon = nil }
    }

    private func handle(_ e: NSEvent) {
        if config.isModifierOnly {

            if Int(e.keyCode) == config.keyCode, e.modifierFlags.contains(config.modifiers) {
                onTrigger()
            }
        } else {
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if Int(e.keyCode) == config.keyCode, mods == config.modifiers {
                onTrigger()
            }
        }
    }
}
