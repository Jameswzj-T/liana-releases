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

/// One pending check for observed chord/cancelled inputs, never for a valid tap.
@MainActor
protocol HotkeyReleaseChecking {
    func schedule(after delay: TimeInterval, _ check: @escaping @MainActor () -> Void) -> Any
    func cancel(_ token: Any)
}

@MainActor
private final class SystemHotkeyReleaseChecking: HotkeyReleaseChecking {
    func schedule(after delay: TimeInterval, _ check: @escaping @MainActor () -> Void) -> Any {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
    func cancel(_ token: Any) { (token as? Timer)?.invalidate() }
}

@MainActor
final class HotkeyManager {
    private let onTrigger: @MainActor () -> Void
    private let canTrigger: @MainActor () -> Bool
    private let pressedMouseButtons: @MainActor () -> Int
    private let isKeyDown: @MainActor (UInt16) -> Bool
    private let isAccessibilityTrusted: @MainActor () -> Bool
    private let monitors: any HotkeyEventMonitoring
    private let releaseChecks: any HotkeyReleaseChecking
    private var releaseCheck: Any?
    private var releaseCheckGeneration: UInt = 0
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
         releaseChecks: (any HotkeyReleaseChecking)? = nil,
         clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.config = config
        self.onTrigger = onTrigger
        self.canTrigger = canTrigger
        self.pressedMouseButtons = pressedMouseButtons
        self.isKeyDown = isKeyDown
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.monitors = monitors ?? SystemHotkeyEventMonitoring()
        self.releaseChecks = releaseChecks ?? SystemHotkeyReleaseChecking()
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
        cancelReleaseCheck()
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
    // No permission prompts or changes to saved shortcuts here.
    func environmentDidChange() {
        guard isMonitoring else { return }
        discardTapEventsThrough = max(discardTapEventsThrough, clock())
        reconcileReleasedInputs()
        if let key = config.standaloneTapKey { tap?.focusChanged(modifierIsDown: isKeyDown(key.code)) }
        if lastAccessibilityTrusted != isAccessibilityTrusted() || globalMon == nil || localMon == nil {
            installMonitors()
        }
        updateReleaseCheck()
    }

    private func cancelReleaseCheck() {
        releaseCheckGeneration &+= 1
        if let token = releaseCheck { releaseChecks.cancel(token) }
        releaseCheck = nil
    }

    private func updateReleaseCheck() {
        guard isMonitoring, tap?.needsReleaseCheck == true else {
            cancelReleaseCheck()
            return
        }
        guard releaseCheck == nil else { return }
        releaseCheckGeneration &+= 1
        let generation = releaseCheckGeneration
        releaseCheck = releaseChecks.schedule(after: 0.25) { [weak self] in
            guard let self, self.isMonitoring, self.releaseCheckGeneration == generation else { return }
            self.releaseCheck = nil
            self.reconcileReleasedInputs()
            self.updateReleaseCheck()
        }
    }

    private func reconcileReleasedInputs() {
        guard let snapshot = tap, snapshot.needsReleaseCheck else { return }
        // Sample only inputs this recognizer saw pressed. Unobserved key-state
        // bits can themselves be stale; a whole-keyboard scan would disable taps.
        let sampledAt = clock()
        let keys = Set(snapshot.observedKeysDown.filter(isKeyDown))
        let modifierDown = snapshot.observedModifierDown && isKeyDown(snapshot.key.code)
        if tap?.reconcileReleasedInputs(keysStillDown: keys, modifierIsDown: modifierDown,
                                       mouseButtons: pressedMouseButtons()) == true {
            discardTapEventsThrough = max(discardTapEventsThrough, sampledAt)
        }
    }

    // Tests feed events here without installing monitors or recording audio.
    func handle(_ e: NSEvent) {
        if tap != nil {
            defer { updateReleaseCheck() }
            guard e.timestamp > discardTapEventsThrough else {
                // Reject old gestures, not evidence of a currently held chord.
                // Otherwise a queued letter-down could be lost while the letter
                // is still held, making the next modifier look like a clean tap.
                if e.type == .keyDown || e.type == .keyUp {
                    tap?.observeDiscardedKey(e.keyCode, physicallyDown: isKeyDown(e.keyCode))
                } else if e.type == .flagsChanged, e.keyCode == tap?.key.code {
                    tap?.focusChanged(modifierIsDown: isKeyDown(e.keyCode))
                } else {
                    tap?.invalidate()
                }
                return
            }
            let keyboard = e.type == .flagsChanged || e.type == .keyDown || e.type == .keyUp
            let checkKeys = e.type == .flagsChanged && e.keyCode == tap!.key.code
                && e.modifierFlags.contains(tap!.key.flag)
            let observed = tap!.observedKeysDown
            let physical = checkKeys ? Set(observed.filter(isKeyDown)) : nil
            if let physical, physical != observed {
                // Physical state is newer than queued NSEvents. Once reconciling,
                // cancel ALL taps created before this point, not just the first.
                discardTapEventsThrough = max(discardTapEventsThrough, clock())
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
