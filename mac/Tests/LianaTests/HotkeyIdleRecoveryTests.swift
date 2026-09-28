import AppKit
import XCTest
@testable import Liana

/// Fake clock, physical state and scheduler: no system monitors, posted keys,
/// permission requests, sleeps, microphone, or application launch.
final class HotkeyIdleRecoveryTests: XCTestCase {
    @MainActor private final class Checks: HotkeyReleaseChecking {
        var next = 0
        var pending: [Int: @MainActor () -> Void] = [:]
        var cancelled: [@MainActor () -> Void] = []
        func schedule(after delay: TimeInterval, _ check: @escaping @MainActor () -> Void) -> Any {
            XCTAssertEqual(delay, 0.25)
            next += 1
            pending[next] = check
            return next
        }
        func cancel(_ token: Any) {
            if let check = pending.removeValue(forKey: token as! Int) { cancelled.append(check) }
        }
        func fire() throws {
            let id = try XCTUnwrap(pending.keys.min())
            let check = try XCTUnwrap(pending.removeValue(forKey: id))
            check()
        }
    }

    @MainActor private final class Monitors: HotkeyEventMonitoring {
        var adds = 0
        func addGlobal(mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> Void) -> Any? {
            adds += 1; return adds
        }
        func addLocal(mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> Void) -> Any? {
            adds += 1; return adds
        }
        func remove(_ token: Any) {}
    }

    @MainActor private final class State {
        var now: TimeInterval = 10
        var keys: Set<UInt16> = []
        var samples: [UInt16] = []
        var mouse = 0
        var trusted = true
        var triggers = 0
        var onSample: ((UInt16) -> Void)?
    }

    @MainActor private final class Harness {
        let state = State()
        let checks = Checks()
        let monitors = Monitors()
        let config: HotkeyConfig
        let manager: HotkeyManager

        init(_ config: HotkeyConfig, systemReleaseCheck: Bool = false) {
            self.config = config
            let state = self.state
            manager = HotkeyManager(config: config, onTrigger: { state.triggers += 1 },
                pressedMouseButtons: { state.mouse },
                isKeyDown: {
                    state.samples.append($0)
                    state.onSample?($0)
                    return state.keys.contains($0)
                },
                isAccessibilityTrusted: { state.trusted }, monitors: monitors,
                releaseChecks: systemReleaseCheck ? nil : checks, clock: { state.now })
            manager.apply(config)
        }

        func key(_ code: UInt16, down: Bool, deliver: Bool = true,
                 timestamp: TimeInterval? = nil) throws {
            state.now += 0.01
            if down { state.keys.insert(code) } else { state.keys.remove(code) }
            if deliver { try queuedKey(code, down: down, timestamp: timestamp ?? state.now) }
        }

        func queuedKey(_ code: UInt16, down: Bool, timestamp: TimeInterval) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero,
                modifierFlags: [], timestamp: timestamp, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            manager.handle(event)
        }

        func modifier(down: Bool, deliver: Bool = true, timestamp: TimeInterval? = nil) throws {
            state.now += 0.01
            let key = try XCTUnwrap(config.standaloneTapKey)
            if down { state.keys.insert(key.code) } else { state.keys.remove(key.code) }
            if deliver { try queuedModifier(down: down, timestamp: timestamp ?? state.now) }
        }

        func queuedModifier(down: Bool, timestamp: TimeInterval) throws {
            let key = try XCTUnwrap(config.standaloneTapKey)
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: down))
            event.type = .flagsChanged
            event.flags = CGEventFlags(rawValue: down ? UInt64(key.flag.rawValue | key.rightMask) : 0)
            event.timestamp = UInt64(timestamp * 1_000_000_000)
            manager.handle(try XCTUnwrap(NSEvent(cgEvent: event)))
        }

        func tap() throws { try modifier(down: true); try modifier(down: false) }
        func recover(after delay: TimeInterval = 0.25) throws {
            state.now += delay
            try checks.fire()
            XCTAssertLessThanOrEqual(checks.pending.count, 1)
        }
    }

    private let configs: [HotkeyConfig] = [.default, .editDefault]

    @MainActor
    func testIdleRecoveryMakesTheFirstTapWorkAfterMissingOrdinaryRelease() throws {
        for config in configs {
            for code: UInt16 in [0, 8, 48, 53, 123] {
                for idle: TimeInterval in [0.25, 60, 3_600] {
                    let h = Harness(config)
                    defer { h.manager.stop() }
                    try h.key(code, down: true)
                    try h.key(code, down: false, deliver: false)
                    try h.recover(after: idle)
                    XCTAssertEqual(h.state.triggers, 0, "Recovery itself must not trigger")
                    try h.tap()
                    XCTAssertEqual(h.state.triggers, 1, "First tap after idle must work")
                    XCTAssertTrue(h.checks.pending.isEmpty)
                }
            }
        }
    }

    @MainActor
    func testIdleRecoveryMakesFirstTapWorkAfterMissingCancelledModifierRelease() throws {
        for config in configs {
            let h = Harness(config)
            defer { h.manager.stop() }
            try h.modifier(down: true)
            try h.key(8, down: true)
            try h.key(8, down: false)
            try h.modifier(down: false, deliver: false)
            try h.recover(after: 60)
            XCTAssertEqual(h.state.triggers, 0)
            try h.tap()
            XCTAssertEqual(h.state.triggers, 1)
        }
    }

    @MainActor
    func testEnvironmentRecoveryClearsOrdinaryResidueBeforeFirstTap() throws {
        for config in configs {
            for trusted in [false, true] {
                let h = Harness(config)
                defer { h.manager.stop() }
                try h.key(8, down: true)
                try h.key(8, down: false, deliver: false)
                h.state.trusted = trusted
                h.manager.environmentDidChange()
                XCTAssertTrue(h.checks.pending.isEmpty)
                try h.tap()
                XCTAssertEqual(h.state.triggers, 1)
            }
        }
    }

    @MainActor
    func testQueuedReleasedKeyDoesNotRecreateResidueAfterRecovery() throws {
        for config in configs {
            let h = Harness(config)
            defer { h.manager.stop() }
            try h.key(0, down: true)
            try h.key(0, down: false, deliver: false)
            let old = h.state.now
            try h.recover()
            try h.queuedKey(8, down: true, timestamp: old)
            XCTAssertTrue(h.checks.pending.isEmpty)
            try h.tap()
            XCTAssertEqual(h.state.triggers, 1)
        }
    }

    @MainActor
    func testQueuedStillHeldKeyMustBlockANewModifierTap() throws {
        for config in configs {
            let h = Harness(config)
            defer { h.manager.stop() }
            try h.key(0, down: true)
            try h.key(0, down: false, deliver: false)
            let old = h.state.now
            // This second key was not observed when the recovery snapshot ran.
            h.state.keys.insert(8)
            h.state.now += 0.25
            try h.checks.fire()
            XCTAssertFalse(h.state.samples.contains(8), "Do not scan an unobserved key")
            try h.queuedKey(8, down: true, timestamp: old)
            try h.tap()
            XCTAssertEqual(h.state.triggers, 0, "A held chord must not become a standalone tap")
            try h.key(8, down: false)
            try h.tap()
            XCTAssertEqual(h.state.triggers, 1)
        }
    }

    @MainActor
    func testOldKeyUpCannotEraseANewerHeldKey() throws {
        for config in configs {
            let h = Harness(config)
            defer { h.manager.stop() }
            let old = h.state.now
            h.manager.environmentDidChange()
            try h.key(8, down: true)
            try h.queuedKey(8, down: false, timestamp: old)
            try h.tap()
            XCTAssertEqual(h.state.triggers, 0)
            try h.key(8, down: false)
            try h.tap()
            XCTAssertEqual(h.state.triggers, 1)
        }
    }

    @MainActor
    func testMultipleQueuedOldChordsNeverTriggerOrPoisonNextFreshTap() throws {
        for config in configs {
            let h = Harness(config)
            defer { h.manager.stop() }
            let old = h.state.now
            h.manager.environmentDidChange()
            for _ in 0..<10 {
                try h.queuedKey(8, down: true, timestamp: old)
                try h.queuedModifier(down: true, timestamp: old)
                try h.queuedModifier(down: false, timestamp: old)
                try h.queuedKey(8, down: false, timestamp: old)
            }
            XCTAssertEqual(h.state.triggers, 0)
            XCTAssertTrue(h.checks.pending.isEmpty)
            try h.tap()
            XCTAssertEqual(h.state.triggers, 1)
        }
    }

    @MainActor
    func testPhysicallyHeldKeysSurviveRepeatedRecoveryChecks() throws {
        for config in configs {
            let h = Harness(config)
            defer { h.manager.stop() }
            try h.key(8, down: true)
            for _ in 0..<10 { try h.recover() }
            try h.tap()
            XCTAssertEqual(h.state.triggers, 0)
            try h.key(8, down: false, deliver: false)
            try h.recover()
            try h.tap()
            XCTAssertEqual(h.state.triggers, 1)
        }
    }

    @MainActor
    func testHeldStandaloneModifierDoesNotNeedOrStartAReleaseCheck() throws {
        for config in configs {
            let h = Harness(config)
            defer { h.manager.stop() }
            try h.modifier(down: true)
            h.state.now += 60
            XCTAssertTrue(h.checks.pending.isEmpty)
            XCTAssertEqual(h.state.triggers, 0)
            try h.modifier(down: false)
            XCTAssertEqual(h.state.triggers, 1)
            XCTAssertTrue(h.checks.pending.isEmpty)
        }
    }

    @MainActor
    func testPhysicalReleaseBeforeQueuedCallbackDoesNotLoseAValidTap() throws {
        for config in configs {
            let h = Harness(config)
            defer { h.manager.stop() }
            try h.key(8, down: true)
            try h.key(8, down: false)
            let cancelled = try XCTUnwrap(h.checks.cancelled.last)
            try h.modifier(down: true)
            try h.modifier(down: false, deliver: false)
            let releasedAt = h.state.now
            h.state.now += 0.25
            cancelled() // Even a late cancelled callback cannot steal the release.
            XCTAssertTrue(h.checks.pending.isEmpty)
            try h.queuedModifier(down: false, timestamp: releasedAt)
            XCTAssertEqual(h.state.triggers, 1)
        }
    }

    @MainActor
    func testHeldMouseStillBlocksAfterKeyboardRecovery() throws {
        for config in configs {
            let h = Harness(config)
            defer { h.manager.stop() }
            try h.key(8, down: true)
            try h.key(8, down: false, deliver: false)
            h.state.now += 0.25
            try h.checks.fire()
            h.state.mouse = 1
            try h.tap()
            XCTAssertEqual(h.state.triggers, 0)
            h.state.mouse = 0
            try h.tap()
            XCTAssertEqual(h.state.triggers, 1)
        }
    }

    @MainActor
    func testFocusChangeDuringAPressRejectsItButNotTheNextFreshTap() throws {
        for config in configs {
            let h = Harness(config)
            defer { h.manager.stop() }
            try h.modifier(down: true)
            h.manager.environmentDidChange()
            try h.modifier(down: false)
            XCTAssertEqual(h.state.triggers, 0)
            try h.tap()
            XCTAssertEqual(h.state.triggers, 1)
        }
    }

    @MainActor
    func testNoChecksOrWholeKeyboardSamplingWhenIdle() throws {
        for config in configs {
            let h = Harness(config)
            defer { h.manager.stop() }
            XCTAssertTrue(h.checks.pending.isEmpty)
            h.state.now += 86_400
            try h.tap()
            XCTAssertEqual(h.state.triggers, 1)
            XCTAssertTrue(h.state.samples.isEmpty)
            XCTAssertTrue(h.checks.pending.isEmpty)
            try h.key(8, down: true)
            try h.recover()
            XCTAssertEqual(Set(h.state.samples), [8])
        }
    }

    @MainActor
    func testStopAndReconfigureMakeCancelledCallbacksHarmless() throws {
        for config in configs {
            let h = Harness(config)
            try h.key(8, down: true)
            h.manager.stop()
            let old = try XCTUnwrap(h.checks.cancelled.last)
            h.state.samples = []
            old()
            XCTAssertTrue(h.state.samples.isEmpty)
            XCTAssertTrue(h.checks.pending.isEmpty)
            XCTAssertEqual(h.monitors.adds, 2)
            h.state.keys = []
            h.manager.apply(config)
            defer { h.manager.stop() }
            try h.modifier(down: true)
            old()
            try h.modifier(down: false)
            XCTAssertEqual(h.state.triggers, 1)
            XCTAssertEqual(h.monitors.adds, 4)
        }
    }

    @MainActor
    func testNormalShortcutDoesNotScheduleReleaseChecks() throws {
        let config = HotkeyConfig(keyCode: 2, modifierRaw: NSEvent.ModifierFlags([.command, .shift]).rawValue,
                                  isModifierOnly: false, display: "⌘⇧D")
        let h = Harness(config)
        defer { h.manager.stop() }
        try h.key(8, down: true)
        h.manager.environmentDidChange()
        XCTAssertTrue(h.checks.pending.isEmpty)
        XCTAssertTrue(h.state.samples.isEmpty)
    }

    @MainActor
    func testRealRunLoopTimerRepairsMissingReleaseWithoutAnySystemMonitor() async throws {
        for config in configs {
            let h = Harness(config, systemReleaseCheck: true)
            defer { h.manager.stop() }
            try h.key(8, down: true)
            try h.key(8, down: false, deliver: false)
            let checked = expectation(description: "Real timer samples the observed released key")
            h.state.onSample = { code in
                if code == 8 {
                    h.state.onSample = nil
                    checked.fulfill()
                }
            }
            await fulfillment(of: [checked], timeout: 2)
            h.state.onSample = nil
            XCTAssertEqual(h.state.triggers, 0)
            try h.tap()
            XCTAssertEqual(h.state.triggers, 1)
            XCTAssertEqual(h.monitors.adds, 2)
        }
    }
}
