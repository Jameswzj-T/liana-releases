import AppKit
import XCTest
@testable import Liana

final class ModifierTapTests: XCTestCase {
    private let keys: [ModifierTap.Key] = [.rightCommand, .rightOption]

    private final class MemoryDefaults: UserDefaults {
        var values: [String: Data] = [:]
        override func data(forKey defaultName: String) -> Data? { values[defaultName] }
    }

    private func flags(_ key: ModifierTap.Key, left: Bool = false, both: Bool = false) -> NSEvent.ModifierFlags {
        let sides = both ? key.leftMask | key.rightMask : (left ? key.leftMask : key.rightMask)
        return NSEvent.ModifierFlags(rawValue: key.flag.rawValue | sides)
    }

    private func leftCode(_ key: ModifierTap.Key) -> UInt16 {
        key == .rightCommand ? 55 : 58
    }

    private func down(_ tap: inout ModifierTap, flags override: NSEvent.ModifierFlags? = nil,
                      mouse: Int? = nil) -> Bool {
        let key = tap.key
        return tap.consume(type: .flagsChanged, keyCode: key.code, flags: override ?? flags(key),
                           physicalMouseButtons: mouse)
    }

    private func up(_ tap: inout ModifierTap, flags: NSEvent.ModifierFlags = []) -> Bool {
        tap.consume(type: .flagsChanged, keyCode: tap.key.code, flags: flags)
    }

    func testKeyMetadataUsesTheCorrectSideBits() {
        XCTAssertEqual(ModifierTap.Key.rightCommand.code, 54)
        XCTAssertEqual(ModifierTap.Key.rightCommand.flag, .command)
        XCTAssertEqual(ModifierTap.Key.rightCommand.leftMask, 0x08)
        XCTAssertEqual(ModifierTap.Key.rightCommand.rightMask, 0x10)
        XCTAssertEqual(ModifierTap.Key.rightOption.code, 61)
        XCTAssertEqual(ModifierTap.Key.rightOption.flag, .option)
        XCTAssertEqual(ModifierTap.Key.rightOption.leftMask, 0x20)
        XCTAssertEqual(ModifierTap.Key.rightOption.rightMask, 0x40)
    }

    func testBothKeysTriggerOnceOnReleaseAndAllowAnImmediateSecondTap() {
        for key in keys {
            var tap = ModifierTap(key: key)
            XCTAssertFalse(up(&tap))
            for _ in 0..<3 {
                XCTAssertFalse(down(&tap))
                XCTAssertTrue(up(&tap))
                XCTAssertFalse(up(&tap))
            }
        }
    }

    func testHoldingAndRepeatedFlagNotificationsNeverRetrigger() {
        for key in keys {
            var tap = ModifierTap(key: key)
            for _ in 0..<30 { XCTAssertFalse(down(&tap)) }
            XCTAssertTrue(up(&tap))
            for _ in 0..<30 { XCTAssertFalse(up(&tap)) }
        }
    }

    func testLeftSideAloneNeverTriggers() {
        for key in keys {
            var tap = ModifierTap(key: key)
            XCTAssertFalse(tap.consume(type: .flagsChanged, keyCode: leftCode(key), flags: flags(key, left: true)))
            XCTAssertFalse(tap.consume(type: .flagsChanged, keyCode: leftCode(key), flags: []))
            XCTAssertFalse(down(&tap))
            XCTAssertTrue(up(&tap))
        }
    }

    func testBothSidesInAllOrdersStaySilentAndRecoverForTheNextTap() {
        for key in keys {
            for aggregateOnly in [false, true] {
                for leftFirst in [false, true] {
                    for leftReleasedFirst in [false, true] {
                        var tap = ModifierTap(key: key)
                        let first = aggregateOnly ? key.flag : flags(key, left: leftFirst)
                        let both = aggregateOnly ? key.flag : flags(key, both: true)
                        let remaining = aggregateOnly ? key.flag : flags(key, left: !leftReleasedFirst)
                        XCTAssertFalse(tap.consume(type: .flagsChanged,
                            keyCode: leftFirst ? leftCode(key) : key.code, flags: first))
                        XCTAssertFalse(tap.consume(type: .flagsChanged,
                            keyCode: leftFirst ? key.code : leftCode(key), flags: both))
                        XCTAssertFalse(tap.consume(type: .flagsChanged,
                            keyCode: leftReleasedFirst ? leftCode(key) : key.code, flags: remaining))
                        XCTAssertFalse(tap.consume(type: .flagsChanged,
                            keyCode: leftReleasedFirst ? key.code : leftCode(key), flags: []))
                        XCTAssertFalse(down(&tap, flags: aggregateOnly ? key.flag : flags(key)))
                        XCTAssertTrue(up(&tap))
                    }
                }
            }
        }
    }

    func testAggregateFlagsSupportBothStandaloneKeys() {
        for key in keys {
            var tap = ModifierTap(key: key)
            XCTAssertFalse(down(&tap, flags: key.flag))
            XCTAssertTrue(up(&tap))
        }
    }

    func testLetterNavigationAndEscapeChordsNeverTriggerInEitherReleaseOrder() {
        for key in keys {
            for code: UInt16 in [8, 9, 0, 6, 48, 53, 36, 123, 124, 125, 126] {
                for letterReleasedFirst in [false, true] {
                    var tap = ModifierTap(key: key)
                    XCTAssertFalse(down(&tap))
                    XCTAssertFalse(tap.consume(type: .keyDown, keyCode: code, flags: flags(key)))
                    XCTAssertFalse(down(&tap)) // A repeated modifier notification cannot re-arm.
                    if letterReleasedFirst {
                        XCTAssertFalse(tap.consume(type: .keyUp, keyCode: code, flags: flags(key)))
                        XCTAssertFalse(up(&tap))
                    } else {
                        XCTAssertFalse(up(&tap))
                        XCTAssertFalse(tap.consume(type: .keyUp, keyCode: code, flags: []))
                    }
                    XCTAssertFalse(down(&tap))
                    XCTAssertTrue(up(&tap))
                }
            }
        }
    }

    func testAKeyHeldBeforeTheModifierPreventsAStandaloneTap() {
        for key in keys {
            var tap = ModifierTap(key: key)
            XCTAssertFalse(tap.consume(type: .keyDown, keyCode: 8, flags: []))
            XCTAssertFalse(down(&tap))
            XCTAssertFalse(up(&tap))
            XCTAssertFalse(tap.consume(type: .keyUp, keyCode: 8, flags: []))
            XCTAssertFalse(down(&tap))
            XCTAssertTrue(up(&tap))
        }
    }

    func testOtherModifiersBeforeOrAfterTheTargetInvalidateTheEntireChord() {
        for key in keys {
            let otherPrimary: (UInt16, NSEvent.ModifierFlags) = key == .rightCommand ? (61, .option) : (54, .command)
            let others: [(UInt16, NSEvent.ModifierFlags)] = [(56, .shift), (59, .control), (63, .function), otherPrimary]
            for (code, flag) in others {
                for otherFirst in [false, true] {
                    var tap = ModifierTap(key: key)
                    if otherFirst {
                        XCTAssertFalse(tap.consume(type: .flagsChanged, keyCode: code, flags: flag))
                        XCTAssertFalse(down(&tap, flags: flags(key).union(flag)))
                    } else {
                        XCTAssertFalse(down(&tap))
                        XCTAssertFalse(tap.consume(type: .flagsChanged, keyCode: code, flags: flags(key).union(flag)))
                    }
                    XCTAssertFalse(tap.consume(type: .flagsChanged, keyCode: code, flags: flags(key)))
                    XCTAssertFalse(up(&tap))
                    XCTAssertFalse(down(&tap))
                    XCTAssertTrue(up(&tap))
                }
            }
        }
    }

    func testMouseAndScrollDuringATapPreventTriggering() {
        let pairs: [(NSEvent.EventType, NSEvent.EventType)] = [
            (.leftMouseDown, .leftMouseUp), (.rightMouseDown, .rightMouseUp),
            (.otherMouseDown, .otherMouseUp), (.scrollWheel, .scrollWheel),
        ]
        for key in keys {
            for (press, release) in pairs {
                var tap = ModifierTap(key: key)
                XCTAssertFalse(down(&tap))
                XCTAssertFalse(tap.consume(type: press, keyCode: 0, flags: flags(key)))
                XCTAssertFalse(tap.consume(type: release, keyCode: 0, flags: flags(key)))
                XCTAssertFalse(down(&tap, mouse: 0))
                XCTAssertFalse(up(&tap))
                XCTAssertFalse(down(&tap, mouse: 0))
                XCTAssertTrue(up(&tap))
            }
        }
    }

    func testObservedMouseHeldBeforeModifierPreventsTap() {
        for key in keys {
            var tap = ModifierTap(key: key)
            XCTAssertFalse(tap.consume(type: .leftMouseDown, keyCode: 0, flags: []))
            XCTAssertFalse(down(&tap))
            XCTAssertFalse(up(&tap))
            XCTAssertFalse(tap.consume(type: .leftMouseUp, keyCode: 0, flags: []))
            XCTAssertFalse(down(&tap))
            XCTAssertTrue(up(&tap))
        }
    }

    func testMissingMouseUpRecoversWhenPhysicalButtonsAreReleased() {
        for key in keys {
            for event: NSEvent.EventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
                var tap = ModifierTap(key: key)
                XCTAssertFalse(tap.consume(type: event, keyCode: 0, flags: []))
                // A control tracking loop may consume mouse-up before the local monitor.
                XCTAssertFalse(down(&tap, mouse: 0))
                XCTAssertTrue(up(&tap))
            }
        }
    }

    func testPhysicalMouseHeldBeforeMonitoringCannotStartRecording() {
        for key in keys {
            for buttons in [1, 2, 4, 8] {
                var tap = ModifierTap(key: key)
                XCTAssertFalse(down(&tap, mouse: buttons))
                XCTAssertFalse(up(&tap))
                XCTAssertFalse(down(&tap, mouse: 0))
                XCTAssertTrue(up(&tap))
            }
        }
    }

    func testPhysicalMouseReleaseCannotRearmAnAlreadyRejectedTap() {
        for key in keys {
            var tap = ModifierTap(key: key)
            XCTAssertFalse(down(&tap, mouse: 1))
            XCTAssertFalse(down(&tap, mouse: 0))
            XCTAssertFalse(up(&tap))
            XCTAssertFalse(down(&tap, mouse: 0))
            XCTAssertTrue(up(&tap))
        }
    }

    func testNonTargetFlagsDoNotPrematurelyClearObservedMouseState() {
        for key in keys {
            var tap = ModifierTap(key: key)
            XCTAssertFalse(tap.consume(type: .leftMouseDown, keyCode: 0, flags: []))
            XCTAssertFalse(tap.consume(type: .flagsChanged, keyCode: 56, flags: .shift,
                                       physicalMouseButtons: 0))
            XCTAssertFalse(tap.consume(type: .flagsChanged, keyCode: 56, flags: [],
                                       physicalMouseButtons: 0))
            XCTAssertFalse(down(&tap))
            XCTAssertFalse(up(&tap))
            XCTAssertFalse(down(&tap, mouse: 0))
            XCTAssertTrue(up(&tap))
        }
    }

    func testCancellationAndReconfigurationDoNotFireOnLeftoverRelease() {
        for key in keys {
            var tap = ModifierTap(key: key)
            XCTAssertFalse(down(&tap))
            tap.invalidate()
            XCTAssertFalse(down(&tap))
            XCTAssertFalse(up(&tap))
            XCTAssertFalse(down(&tap))
            tap = ModifierTap(key: key)
            XCTAssertFalse(up(&tap))
            XCTAssertFalse(down(&tap))
            XCTAssertTrue(up(&tap))
        }
    }

    func testCapsLockDoesNotPreventAStandaloneTap() {
        for key in keys {
            var tap = ModifierTap(key: key)
            XCTAssertFalse(down(&tap, flags: flags(key).union(.capsLock)))
            XCTAssertTrue(up(&tap, flags: .capsLock))
        }
    }

    func testDefaultsAreRightCommandAndRightOptionWithoutChangingFixShortcut() {
        XCTAssertEqual(HotkeyConfig.default.standaloneTapKey?.code, 54)
        XCTAssertEqual(HotkeyConfig.editDefault.standaloneTapKey?.code, 61)
        XCTAssertEqual(HotkeyConfig.default.prettyDisplay, "右⌘")
        XCTAssertEqual(HotkeyConfig.editDefault.prettyDisplay, "右⌥")
        XCTAssertNil(HotkeyConfig.fixDefault.standaloneTapKey)
        XCTAssertEqual(HotkeyConfig.fixDefault.keyCode, 32)
        XCTAssertEqual(HotkeyConfig.fixDefault.modifiers, [.command, .shift])
    }

    func testSavedLegacyAndCustomConfigurationsOverrideNewDefaults() throws {
        let defaults = try XCTUnwrap(MemoryDefaults(suiteName: "modifier-tests-\(UUID().uuidString)"))
        XCTAssertEqual(HotkeyConfig.load(key: "hotkeyConfig", fallback: .default, defaults: defaults), .default)
        XCTAssertEqual(HotkeyConfig.load(key: "editHotkeyConfig", fallback: .editDefault, defaults: defaults), .editDefault)
        let oldDictation = HotkeyConfig(keyCode: 2, modifierRaw: NSEvent.ModifierFlags([.command, .shift]).rawValue,
                                       isModifierOnly: false, display: "⌘⇧D")
        let oldEdit = HotkeyConfig(keyCode: 14, modifierRaw: NSEvent.ModifierFlags([.command, .shift]).rawValue,
                                  isModifierOnly: false, display: "⌘⇧E")
        let custom = HotkeyConfig(keyCode: 62, modifierRaw: NSEvent.ModifierFlags.control.rawValue,
                                 isModifierOnly: true, display: "右⌃")
        defaults.values["hotkeyConfig"] = try JSONEncoder().encode(oldDictation)
        defaults.values["editHotkeyConfig"] = try JSONEncoder().encode(oldEdit)
        XCTAssertEqual(HotkeyConfig.load(key: "hotkeyConfig", fallback: .default, defaults: defaults), oldDictation)
        XCTAssertEqual(HotkeyConfig.load(key: "editHotkeyConfig", fallback: .editDefault, defaults: defaults), oldEdit)
        defaults.values["editHotkeyConfig"] = try JSONEncoder().encode(custom)
        XCTAssertEqual(HotkeyConfig.load(key: "editHotkeyConfig", fallback: .editDefault, defaults: defaults), custom)
        XCTAssertNil(custom.standaloneTapKey)
    }

    func testOnlyExactStandaloneRightModifiersUseTapRecognition() {
        let configurations = [
            HotkeyConfig(keyCode: 55, modifierRaw: NSEvent.ModifierFlags.command.rawValue, isModifierOnly: true, display: "left"),
            HotkeyConfig(keyCode: 58, modifierRaw: NSEvent.ModifierFlags.option.rawValue, isModifierOnly: true, display: "left"),
            HotkeyConfig(keyCode: 54, modifierRaw: NSEvent.ModifierFlags([.command, .shift]).rawValue, isModifierOnly: true, display: "chord"),
            HotkeyConfig(keyCode: 61, modifierRaw: NSEvent.ModifierFlags.option.rawValue, isModifierOnly: false, display: "key"),
        ]
        for config in configurations { XCTAssertNil(config.standaloneTapKey) }
    }

    func testMalformedSavedConfigurationFallsBackWithoutRewritingIt() throws {
        let defaults = try XCTUnwrap(MemoryDefaults(suiteName: "modifier-tests-\(UUID().uuidString)"))
        let malformed = Data("not a configuration".utf8)
        defaults.values["editHotkeyConfig"] = malformed
        XCTAssertEqual(HotkeyConfig.load(key: "editHotkeyConfig", fallback: .editDefault, defaults: defaults), .editDefault)
        XCTAssertEqual(defaults.values["editHotkeyConfig"], malformed)
    }

    func testPermissionGateAllowsOnlyOnePendingStartAndOneCompletion() throws {
        var gate = RecordingStartGate()
        XCTAssertFalse(gate.isPending)
        let token = try XCTUnwrap(gate.begin())
        XCTAssertTrue(gate.isPending)
        XCTAssertNil(gate.begin())
        XCTAssertTrue(gate.finish(token))
        XCTAssertFalse(gate.isPending)
        XCTAssertFalse(gate.finish(token))
    }

    func testCancelledPermissionResultCannotStartOrClearANewerRequest() throws {
        var gate = RecordingStartGate()
        let old = try XCTUnwrap(gate.begin())
        gate.cancel()
        XCTAssertFalse(gate.finish(old))
        let current = try XCTUnwrap(gate.begin())
        XCTAssertFalse(gate.finish(old))
        XCTAssertEqual(gate.pending, current)
        XCTAssertTrue(gate.finish(current))
        XCTAssertFalse(gate.isPending)
    }
}
