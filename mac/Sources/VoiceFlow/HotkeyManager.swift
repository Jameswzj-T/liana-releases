import AppKit



@MainActor
final class HotkeyManager {
    private let onTrigger: @MainActor () -> Void
    private let canTrigger: @MainActor () -> Bool
    private let pressedMouseButtons: @MainActor () -> Int
    private var config: HotkeyConfig
    private var globalMon: Any?
    private var localMon: Any?
    private var activationObserver: NSObjectProtocol?
    private var tap: ModifierTap?

    init(config: HotkeyConfig = .default, onTrigger: @escaping @MainActor () -> Void,
         canTrigger: @escaping @MainActor () -> Bool = { true },
         pressedMouseButtons: @escaping @MainActor () -> Int = { NSEvent.pressedMouseButtons }) {
        self.config = config
        self.onTrigger = onTrigger
        self.canTrigger = canTrigger
        self.pressedMouseButtons = pressedMouseButtons
        self.tap = config.standaloneTapKey.map { ModifierTap(key: $0) }
    }

    func apply(_ cfg: HotkeyConfig) {
        config = cfg
        stop()
        let mask: NSEvent.EventTypeMask = cfg.standaloneTapKey != nil
            ? ModifierTap.eventMask : (cfg.isModifierOnly ? .flagsChanged : .keyDown)
        globalMon = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }
        localMon = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidatePendingTap() }
        }
        vlog("热键已应用: \(cfg.prettyDisplay)  modifierOnly=\(cfg.isModifierOnly)")
    }

    func stop() {
        tap = config.standaloneTapKey.map { ModifierTap(key: $0) }
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
        if let m = globalMon { NSEvent.removeMonitor(m); globalMon = nil }
        if let m = localMon { NSEvent.removeMonitor(m); localMon = nil }
    }

    func invalidatePendingTap() { tap?.invalidate() }

    // Tests feed events here without installing monitors or recording audio.
    func handle(_ e: NSEvent) {
        if tap != nil {
            let keyboard = e.type == .flagsChanged || e.type == .keyDown || e.type == .keyUp
            let trigger = tap!.consume(type: e.type, keyCode: keyboard ? e.keyCode : 0, flags: e.modifierFlags,
                                       physicalMouseButtons: pressedMouseButtons())
            guard canTrigger() else { tap?.invalidate(); return }
            if trigger { onTrigger() }
        } else if config.isModifierOnly {

            if canTrigger(), Int(e.keyCode) == config.keyCode, e.modifierFlags.contains(config.modifiers) {
                onTrigger()
            }
        } else {
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if canTrigger(), !e.isARepeat, Int(e.keyCode) == config.keyCode, mods == config.modifiers {
                onTrigger()
            }
        }
    }
}
