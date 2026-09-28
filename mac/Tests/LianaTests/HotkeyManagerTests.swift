import AppKit
import XCTest
@testable import Liana

/// Constructed events are never posted to the system; these tests install no monitors.
final class HotkeyManagerTests: XCTestCase {
    @MainActor private final class Availability {
        var allowed = true
        var mouseButtons = 0
    }

    private let configs: [HotkeyConfig] = [.default, .editDefault]

    private func flags(_ raw: UInt, key: UInt16) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true))
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: UInt64(raw))
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func down(_ config: HotkeyConfig) throws -> NSEvent {
        let key = try XCTUnwrap(config.standaloneTapKey)
        return try flags(key.flag.rawValue | key.rightMask, key: key.code)
    }

    private func up(_ config: HotkeyConfig) throws -> NSEvent {
        try flags(0, key: UInt16(config.keyCode))
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
            let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 }, pressedMouseButtons: { 0 })
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
            let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 }, pressedMouseButtons: { 0 })
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
                let first = HotkeyManager(config: .default, onTrigger: { dictation += 1 }, pressedMouseButtons: { 0 })
                let second = HotkeyManager(config: .editDefault, onTrigger: { editing += 1 }, pressedMouseButtons: { 0 })
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
                canTrigger: { state.allowed }, pressedMouseButtons: { 0 })
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
                canTrigger: { state.allowed }, pressedMouseButtons: { 0 })
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
            let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 }, pressedMouseButtons: { 0 })
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
                pressedMouseButtons: { state.mouseButtons })
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
                pressedMouseButtons: { state.mouseButtons })
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
            pressedMouseButtons: { XCTFail("A normal key shortcut must not sample mouse state"); return 0 })
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
        let manager = HotkeyManager(config: config, onTrigger: { triggers += 1 }, pressedMouseButtons: { 0 })
        manager.handle(try flags(NSEvent.ModifierFlags.control.rawValue | 0x2000, key: 62))
        XCTAssertEqual(triggers, 1)
        manager.handle(try flags(0, key: 62))
        XCTAssertEqual(triggers, 1)
    }
}
