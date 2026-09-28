import AppKit
import XCTest
@testable import Liana

/// Constructed events are never posted to the system; these tests install no monitors.
final class HotkeyManagerTests: XCTestCase {
    @MainActor private final class Availability {
        var allowed = true
        var mouseButtons = 0
        var keys: Set<UInt16> = []
        var trusted = false
    }

    @MainActor private final class Monitors: HotkeyEventMonitoring {
        var globalAttempts = 0
        var localAttempts = 0
        var failGlobal = false
        var failLocal = false
        var nextToken = 0
        var handlers: [Int: @MainActor (NSEvent) -> Void] = [:]
        var masks: [NSEvent.EventTypeMask] = []
        func addGlobal(mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> Void) -> Any? {
            globalAttempts += 1
            return failGlobal ? nil : add(mask, handler)
        }
        func addLocal(mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> Void) -> Any? {
            localAttempts += 1
            return failLocal ? nil : add(mask, handler)
        }
        private func add(_ mask: NSEvent.EventTypeMask, _ handler: @escaping @MainActor (NSEvent) -> Void) -> Int {
            nextToken += 1
            handlers[nextToken] = handler
            masks.append(mask)
            return nextToken
        }
        func remove(_ token: Any) { handlers.removeValue(forKey: token as! Int) }
    }

    private let configs: [HotkeyConfig] = [.default, .editDefault]

    private func flags(_ raw: UInt, key: UInt16, timestamp: TimeInterval = 1) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true))
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: UInt64(raw))
        event.timestamp = UInt64(timestamp * 1_000_000_000)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func down(_ config: HotkeyConfig, timestamp: TimeInterval = 1) throws -> NSEvent {
        let key = try XCTUnwrap(config.standaloneTapKey)
        return try flags(key.flag.rawValue | key.rightMask, key: key.code, timestamp: timestamp)
    }

    private func up(_ config: HotkeyConfig, timestamp: TimeInterval = 1) throws -> NSEvent {
        try flags(0, key: UInt16(config.keyCode), timestamp: timestamp)
    }

    private func key(_ code: UInt16, type: NSEvent.EventType = .keyDown,
                     flags: NSEvent.ModifierFlags = [], repeating: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: repeating, keyCode: code))
    }

    private func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    @MainActor
    func testBothDefaultKeysDispatchOnlyOnReleaseAndSupportTwoQuickTaps() throws {
        for config in configs {
            var triggers = 0
            let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 }, pressedMouseButtons: { 0 }, isKeyDown: { _ in false })
            for expected in 1...2 {
                manager.handle(try down(config))
                XCTAssertEqual(triggers, expected - 1)
                manager.handle(try up(config))
                XCTAssertEqual(triggers, expected)
            }
        }
    }

    @MainActor
    func testKeyChordsDoNotDispatchAndTheNextCleanTapRecovers() throws {
        for config in configs {
            var triggers = 0
            let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 }, pressedMouseButtons: { 0 }, isKeyDown: { _ in false })
            for code: UInt16 in [8, 9, 123, 124] {
                manager.handle(try down(config))
                manager.handle(try key(code, flags: config.modifiers))
                manager.handle(try key(code, type: .keyUp, flags: config.modifiers))
                manager.handle(try up(config))
            }
            XCTAssertEqual(triggers, 0)
            manager.handle(try down(config))
            manager.handle(try up(config))
            XCTAssertEqual(triggers, 1)
        }
    }

    @MainActor
    func testRightCommandAndOptionChordsNeverDispatchEitherManager() throws {
        let command: UInt = NSEvent.ModifierFlags.command.rawValue | 0x10
        let option: UInt = NSEvent.ModifierFlags.option.rawValue | 0x40
        for commandFirst in [false, true] {
            for commandReleasedFirst in [false, true] {
                var dictation = 0
                var editing = 0
                let first = HotkeyManager(config: .default, onTrigger: { dictation += 1 }, pressedMouseButtons: { 0 }, isKeyDown: { _ in false })
                let second = HotkeyManager(config: .editDefault, onTrigger: { editing += 1 }, pressedMouseButtons: { 0 }, isKeyDown: { _ in false })
                let sequence: [(UInt16, UInt)] = [
                    (commandFirst ? 54 : 61, commandFirst ? command : option),
                    (commandFirst ? 61 : 54, command | option),
                    (commandReleasedFirst ? 54 : 61, commandReleasedFirst ? option : command),
                    (commandReleasedFirst ? 61 : 54, 0),
                ]
                for (code, raw) in sequence {
                    let event = try flags(raw, key: code)
                    first.handle(event)
                    second.handle(event)
                }
                XCTAssertEqual(dictation, 0)
                XCTAssertEqual(editing, 0)
                for config in configs {
                    for event in [try down(config), try up(config)] {
                        first.handle(event)
                        second.handle(event)
                    }
                }
                XCTAssertEqual(dictation, 1)
                XCTAssertEqual(editing, 1)
            }
        }
    }

    @MainActor
    func testBusyAtPressCannotDispatchAfterBusyEnds() throws {
        for config in configs {
            var triggers = 0
            let state = Availability()
            state.allowed = false
            let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 },
                canTrigger: { state.allowed }, pressedMouseButtons: { 0 }, isKeyDown: { _ in false })
            manager.handle(try down(config))
            state.allowed = true
            manager.handle(try down(config)) // Repeated flags must not re-arm it.
            manager.handle(try up(config))
            XCTAssertEqual(triggers, 0)
            manager.handle(try down(config))
            manager.handle(try up(config))
            XCTAssertEqual(triggers, 1)
        }
    }

    @MainActor
    func testBusyAtReleaseSuppressesBothKeysAndRecovers() throws {
        for config in configs {
            var triggers = 0
            let state = Availability()
            let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 },
                canTrigger: { state.allowed }, pressedMouseButtons: { 0 }, isKeyDown: { _ in false })
            manager.handle(try down(config))
            state.allowed = false
            manager.handle(try up(config))
            XCTAssertEqual(triggers, 0)
            state.allowed = true
            manager.handle(try down(config))
            manager.handle(try up(config))
            XCTAssertEqual(triggers, 1)
        }
    }

    @MainActor
    func testCancellationAndStopSuppressLeftoverReleaseForBothKeys() throws {
        for config in configs {
            var triggers = 0
            let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 }, pressedMouseButtons: { 0 }, isKeyDown: { _ in false })
            manager.handle(try down(config))
            manager.invalidatePendingTap()
            manager.handle(try up(config))
            manager.handle(try down(config))
            manager.stop()
            manager.handle(try up(config))
            XCTAssertEqual(triggers, 0)
            manager.handle(try down(config))
            manager.handle(try up(config))
            XCTAssertEqual(triggers, 1)
        }
    }

    @MainActor
    func testMouseEventsUseSafePropertiesAndPhysicalReleaseRecovers() throws {
        for config in configs {
            var triggers = 0
            let state = Availability()
            let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 },
                pressedMouseButtons: { state.mouseButtons }, isKeyDown: { _ in false })
            manager.handle(try down(config))
            state.mouseButtons = 1
            manager.handle(try mouse(.leftMouseDown))
            manager.handle(try up(config))
            XCTAssertEqual(triggers, 0)
            // Deliberately omit mouse-up to represent an AppKit tracking loop.
            state.mouseButtons = 0
            manager.handle(try down(config))
            manager.handle(try up(config))
            XCTAssertEqual(triggers, 1)
        }
    }

    @MainActor
    func testPhysicalMouseAlreadyHeldSuppressesBothManagers() throws {
        for config in configs {
            var triggers = 0
            let state = Availability()
            state.mouseButtons = 2
            let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 },
                pressedMouseButtons: { state.mouseButtons }, isKeyDown: { _ in false })
            manager.handle(try down(config))
            state.mouseButtons = 0
            manager.handle(try up(config))
            XCTAssertEqual(triggers, 0)
            manager.handle(try down(config))
            manager.handle(try up(config))
            XCTAssertEqual(triggers, 1)
        }
    }

    @MainActor
    func testSavedCombinationStillDispatchesButKeyRepeatDoesNot() throws {
        let config = HotkeyConfig(keyCode: 2, modifierRaw: NSEvent.ModifierFlags([.command, .shift]).rawValue,
                                  isModifierOnly: false, display: "⌘⇧D")
        var triggers = 0
        let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 },
            pressedMouseButtons: { XCTFail("A normal key shortcut must not sample mouse state"); return 0 }, isKeyDown: { _ in false })
        manager.handle(try key(2, flags: [.command, .shift]))
        for _ in 0..<10 { manager.handle(try key(2, flags: [.command, .shift], repeating: true)) }
        XCTAssertEqual(triggers, 1)
        manager.handle(try key(2, flags: [.command]))
        XCTAssertEqual(triggers, 1)
        manager.handle(try key(2, flags: [.command, .shift]))
        XCTAssertEqual(triggers, 2)
    }

    @MainActor
    func testSavedOtherModifierKeepsItsExistingPressBehavior() throws {
        let config = HotkeyConfig(keyCode: 62, modifierRaw: NSEvent.ModifierFlags.control.rawValue,
                                  isModifierOnly: true, display: "右⌃")
        var triggers = 0
        let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 }, pressedMouseButtons: { 0 }, isKeyDown: { _ in false })
        manager.handle(try flags(NSEvent.ModifierFlags.control.rawValue | 0x2000, key: 62))
        XCTAssertEqual(triggers, 1)
        manager.handle(try flags(0, key: 62))
        XCTAssertEqual(triggers, 1)
    }

    @MainActor
    func testMissingOrdinaryKeyUpDoesNotDisableFutureTaps() throws {
        for config in configs {
            for code: UInt16 in [0, 8, 48, 53, 123] {
                var triggers = 0
                let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 },
                    pressedMouseButtons: { 0 }, isKeyDown: { _ in false }, clock: { 2 })
                manager.handle(try key(code)) // Deliberately drop keyUp.
                // Conservatively discard the recovery tap: a delayed callback
                // must not reinterpret an observed chord as a standalone tap.
                manager.handle(try down(config))
                manager.handle(try up(config))
                XCTAssertEqual(triggers, 0)
                for _ in 0..<3 {
                    manager.handle(try down(config, timestamp: 3))
                    manager.handle(try up(config, timestamp: 3))
                }
                XCTAssertEqual(triggers, 3)
            }
        }
    }

    @MainActor
    func testDelayedChordCallbacksCannotBeReclassifiedAsStandaloneTaps() throws {
        for config in configs {
            var triggers = 0
            let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 },
                pressedMouseButtons: { 0 }, isKeyDown: { _ in false }, clock: { 2 })
            // All physical keys are already up while the queued events drain.
            manager.handle(try key(8))
            for _ in 0..<3 {
                manager.handle(try down(config))
                manager.handle(try up(config))
            }
            manager.handle(try key(8, type: .keyUp))
            XCTAssertEqual(triggers, 0)
            manager.handle(try down(config, timestamp: 3))
            manager.handle(try up(config, timestamp: 3))
            XCTAssertEqual(triggers, 1)
        }
    }

    @MainActor
    func testPhysicallyHeldObservedKeyIsNotClearedByRecovery() throws {
        for config in configs {
                var triggers = 0
                let state = Availability()
                state.keys = [8]
                let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 },
                    pressedMouseButtons: { 0 }, isKeyDown: { state.keys.contains($0) }, clock: { 2 })
                manager.handle(try key(8))
                manager.handle(try down(config))
                state.keys = [] // Key released, but do not send keyUp.
                manager.handle(try up(config))
                XCTAssertEqual(triggers, 0)
                manager.handle(try down(config))
                manager.handle(try up(config))
                XCTAssertEqual(triggers, 0) // Recovery discards this tap too.
                manager.handle(try down(config, timestamp: 3))
                manager.handle(try up(config, timestamp: 3))
                XCTAssertEqual(triggers, 1)
        }
    }

    @MainActor
    func testOrdinaryKeysThatWereNeverObservedAreNotPolled() throws {
        for config in configs {
            var triggers = 0
            let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 },
                pressedMouseButtons: { 0 }, isKeyDown: { _ in XCTFail("No observed keys to reconcile"); return true })
            manager.handle(try down(config))
            manager.handle(try up(config))
            XCTAssertEqual(triggers, 1)
        }
    }

    @MainActor
    func testFocusChangeCancelsOldTapWithoutBreakingNextTap() throws {
        for config in configs {
            for stillHeld in [false, true] {
                var triggers = 0
                let state = Availability()
                let monitors = Monitors()
                let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 },
                    pressedMouseButtons: { 0 }, isKeyDown: { state.keys.contains($0) },
                    isAccessibilityTrusted: { true }, monitors: monitors, clock: { 2 })
                manager.apply(config)
                defer { manager.stop() }
                manager.handle(try down(config))
                state.keys = stillHeld ? [UInt16(config.keyCode)] : []
                manager.environmentDidChange()
                if stillHeld { manager.handle(try down(config)) } // Cannot re-arm held modifier.
                state.keys = []
                manager.handle(try up(config))
                XCTAssertEqual(triggers, 0)
                manager.handle(try down(config, timestamp: 3))
                manager.handle(try up(config, timestamp: 3))
                XCTAssertEqual(triggers, 1)
                XCTAssertEqual(monitors.globalAttempts, 1)
                XCTAssertEqual(monitors.handlers.count, 2)
            }
        }
    }

    @MainActor
    func testLostModifierReleaseRecoversOnFocusChange() throws {
        for config in configs {
            var triggers = 0
            let monitors = Monitors()
            let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 },
                pressedMouseButtons: { 0 }, isKeyDown: { _ in false },
                isAccessibilityTrusted: { true }, monitors: monitors, clock: { 2 })
            manager.apply(config)
            defer { manager.stop() }
            manager.handle(try down(config)) // Lost modifier release, not a held modifier.
            manager.environmentDidChange()
            manager.handle(try down(config, timestamp: 3))
            manager.handle(try up(config, timestamp: 3))
            XCTAssertEqual(triggers, 1)
        }
    }

    @MainActor
    func testFocusRecoveryDiscardsQueuedTapsAndCannotFinishAnOldPress() throws {
        for config in configs {
            var triggers = 0
            let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 },
                pressedMouseButtons: { 0 }, isKeyDown: { _ in false },
                isAccessibilityTrusted: { true }, monitors: Monitors(), clock: { 2 })
            manager.apply(config)
            defer { manager.stop() }
            manager.environmentDidChange()
            for _ in 0..<3 {
                manager.handle(try down(config))
                manager.handle(try up(config))
            }
            manager.handle(try down(config, timestamp: 2))
            manager.handle(try up(config, timestamp: 3))
            XCTAssertEqual(triggers, 0)
            manager.handle(try down(config, timestamp: 4))
            manager.handle(try up(config, timestamp: 4))
            XCTAssertEqual(triggers, 1)
        }
    }

    @MainActor
    func testPermissionTransitionsReinstallOnceAndStopCannotRestart() throws {
        let state = Availability()
        let monitors = Monitors()
        let manager = HotkeyManager(onTrigger: { XCTFail("Recovery must not dispatch") },
            isKeyDown: { _ in false }, isAccessibilityTrusted: { state.trusted }, monitors: monitors)
        manager.apply(.default)
        defer { manager.stop() }
        for _ in 0..<10 { manager.environmentDidChange() }
        XCTAssertEqual(monitors.globalAttempts, 1)
        state.trusted = true
        manager.environmentDidChange()
        for _ in 0..<10 { manager.environmentDidChange() }
        XCTAssertEqual(monitors.globalAttempts, 2)
        XCTAssertEqual(monitors.handlers.count, 2)
        state.trusted = false
        manager.environmentDidChange()
        XCTAssertEqual(monitors.globalAttempts, 3)
        XCTAssertEqual(monitors.handlers.count, 2)
        manager.stop()
        state.trusted = true
        manager.environmentDidChange()
        XCTAssertEqual(monitors.globalAttempts, 3)
        XCTAssertTrue(monitors.handlers.isEmpty)
    }

    @MainActor
    func testFailedMonitorRegistrationRetriesOnEnvironmentChange() {
        for global in [false, true] {
            let monitors = Monitors()
            monitors.failGlobal = global
            monitors.failLocal = !global
            let manager = HotkeyManager(onTrigger: { XCTFail("Recovery must not dispatch") },
                isKeyDown: { _ in false }, isAccessibilityTrusted: { true }, monitors: monitors)
            manager.apply(.default)
            XCTAssertEqual(monitors.handlers.count, 1)
            monitors.failGlobal = false
            monitors.failLocal = false
            manager.environmentDidChange()
            XCTAssertEqual(monitors.globalAttempts, 2)
            XCTAssertEqual(monitors.localAttempts, 2)
            XCTAssertEqual(monitors.handlers.count, 2)
            manager.stop()
        }
    }

    @MainActor
    func testRecoveryRetainsCustomShortcutAndDoesNotAccumulateMonitors() throws {
        var triggers = 0
        let state = Availability()
        let monitors = Monitors()
        let config = HotkeyConfig(keyCode: 2, modifierRaw: NSEvent.ModifierFlags([.command, .shift]).rawValue,
                                  isModifierOnly: false, display: "⌘⇧D")
        let manager = HotkeyManager(onTrigger: { triggers += 1 },
            isKeyDown: { _ in false }, isAccessibilityTrusted: { state.trusted }, monitors: monitors)
        manager.apply(.default)
        manager.apply(config)
        defer { manager.stop() }
        state.trusted = true
        manager.environmentDidChange()
        XCTAssertEqual(monitors.handlers.count, 2)
        XCTAssertEqual(monitors.masks.suffix(2), [.keyDown, .keyDown])
        let event = try key(2, flags: [.command, .shift])
        try XCTUnwrap(monitors.handlers.values.first)(event)
        XCTAssertEqual(triggers, 1)
    }
}
