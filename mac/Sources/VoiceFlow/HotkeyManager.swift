import AppKit

/// Injectable so recovery tests install no system keyboard monitors.
@MainActor
protocol HotkeyEventMonitoring {
    func addGlobal(mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> Void) -> Any?
    func addLocal(mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> Void) -> Any?
    func remove(_ token: Any)
}

@MainActor
private final class SystemHotkeyEventMonitoring: HotkeyEventMonitoring {
    func addGlobal(mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> Void) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { handler(event) }
        }
    }
    func addLocal(mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> Void) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { handler(event) }
            return event
        }
    }
    func remove(_ token: Any) { NSEvent.removeMonitor(token) }
}

@MainActor
final class HotkeyManager {
    private let onTrigger: @MainActor () -> Void
    private let canTrigger: @MainActor () -> Bool
    private let pressedMouseButtons: @MainActor () -> Int
    private let isKeyDown: @MainActor (UInt16) -> Bool
    private let isAccessibilityTrusted: @MainActor () -> Bool
    private let monitors: any HotkeyEventMonitoring
    private let clock: @MainActor () -> TimeInterval
    private var discardTapEventsThrough = -Double.infinity
    private var config: HotkeyConfig
    private var globalMon: Any?
    private var localMon: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var activationObserver: NSObjectProtocol?
    private var lastAccessibilityTrusted = false
    private var isMonitoring = false
    private var tap: ModifierTap?

    init(config: HotkeyConfig = .default, onTrigger: @escaping @MainActor () -> Void,
         canTrigger: @escaping @MainActor () -> Bool = { true },
         pressedMouseButtons: @escaping @MainActor () -> Int = { NSEvent.pressedMouseButtons },
         isKeyDown: @escaping @MainActor (UInt16) -> Bool = {
             CGEventSource.keyState(.combinedSessionState, key: $0)
         },
         isAccessibilityTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
         monitors: (any HotkeyEventMonitoring)? = nil,
         clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.config = config
        self.onTrigger = onTrigger
        self.canTrigger = canTrigger
        self.pressedMouseButtons = pressedMouseButtons
        self.isKeyDown = isKeyDown
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.monitors = monitors ?? SystemHotkeyEventMonitoring()
        self.clock = clock
        self.tap = config.standaloneTapKey.map { ModifierTap(key: $0) }
    }

    func apply(_ cfg: HotkeyConfig) {
        config = cfg
        stop()
        isMonitoring = true
        installMonitors()
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.environmentDidChange() }
            })
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.environmentDidChange() }
        }
        vlog("热键已应用: \(cfg.prettyDisplay)  modifierOnly=\(cfg.isModifierOnly)")
    }

    func stop() {
        isMonitoring = false
        discardTapEventsThrough = -Double.infinity
        tap = config.standaloneTapKey.map { ModifierTap(key: $0) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        if let observer = activationObserver {
            NotificationCenter.default.removeObserver(observer)
            activationObserver = nil
        }
        removeMonitors()
    }

    func invalidatePendingTap() { tap?.invalidate() }

    private func removeMonitors() {
        if let m = globalMon { monitors.remove(m); globalMon = nil }
        if let m = localMon { monitors.remove(m); localMon = nil }
    }

    private func installMonitors() {
        removeMonitors()
        lastAccessibilityTrusted = isAccessibilityTrusted()
        let mask: NSEvent.EventTypeMask = config.standaloneTapKey != nil
            ? ModifierTap.eventMask : (config.isModifierOnly ? .flagsChanged : .keyDown)
        globalMon = monitors.addGlobal(mask: mask) { [weak self] in self?.handle($0) }
        localMon = monitors.addLocal(mask: mask) { [weak self] in self?.handle($0) }
    }

    // Permission changes, app switching, wake and unlock must not require a restart.
    // No permission prompts, timer polling, or changes to saved shortcuts here.
    func environmentDidChange() {
        guard isMonitoring else { return }
        discardTapEventsThrough = clock()
        if let key = config.standaloneTapKey { tap?.focusChanged(modifierIsDown: isKeyDown(key.code)) }
        if lastAccessibilityTrusted != isAccessibilityTrusted() || globalMon == nil || localMon == nil {
            installMonitors()
        }
    }

    // Tests feed events here without installing monitors or recording audio.
    func handle(_ e: NSEvent) {
        if tap != nil {
            let keyboard = e.type == .flagsChanged || e.type == .keyDown || e.type == .keyUp
            let checkKeys = e.type == .flagsChanged && e.keyCode == tap!.key.code
                && e.modifierFlags.contains(tap!.key.flag)
            let observed = tap!.observedKeysDown
            let physical = checkKeys ? Set(observed.filter(isKeyDown)) : nil
            if let physical, physical != observed {
                // Physical state is newer than queued NSEvents. Once reconciling,
                // cancel ALL taps created before this point, not just the first.
                discardTapEventsThrough = clock()
            }
            let trigger = tap!.consume(type: e.type, keyCode: keyboard ? e.keyCode : 0, flags: e.modifierFlags,
                                       physicalMouseButtons: pressedMouseButtons(),
                                       physicalKeysDown: physical)
            guard e.timestamp > discardTapEventsThrough, canTrigger() else { tap?.invalidate(); return }
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
