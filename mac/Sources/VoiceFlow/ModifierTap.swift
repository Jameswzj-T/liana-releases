import AppKit

/// Standalone right-side modifiers fire once on release, never on key-down.
/// Keyboard/mouse chords remain available to the foreground application.
struct ModifierTap {
    enum Key {
        case rightCommand, rightOption
        var code: UInt16 { self == .rightCommand ? 54 : 61 }
        var flag: NSEvent.ModifierFlags { self == .rightCommand ? .command : .option }
        // IOKit/hidsystem/IOLLEvent.h per-side modifier flags.
        var leftMask: UInt { self == .rightCommand ? 0x08 : 0x20 }
        var rightMask: UInt { self == .rightCommand ? 0x10 : 0x40 }
    }
    static let eventMask: NSEvent.EventTypeMask = [
        .flagsChanged, .keyDown, .keyUp, .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel
    ]
    private static let chordModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .function]
    let key: Key
    private var isDown = false
    private var eligible = false
    private var keysDown: Set<UInt16> = []
    var observedKeysDown: Set<UInt16> { keysDown }
    private var buttonsDown: Set<NSEvent.EventType> = []

    init(key: Key) { self.key = key }
    mutating func invalidate() { eligible = false }
    mutating func focusChanged(modifierIsDown: Bool) {
        // Never finish a tap that began in another focus/permission session.
        isDown = modifierIsDown
        eligible = false
    }

    mutating func consume(type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags,
                          physicalMouseButtons: Int? = nil,
                          physicalKeysDown: Set<UInt16>? = nil) -> Bool {
        guard type == .flagsChanged else {
            if type == .keyDown { keysDown.insert(keyCode) }
            if type == .keyUp { keysDown.remove(keyCode) }
            switch type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: buttonsDown.insert(type)
            case .leftMouseUp: buttonsDown.remove(.leftMouseDown)
            case .rightMouseUp: buttonsDown.remove(.rightMouseDown)
            case .otherMouseUp: buttonsDown.remove(.otherMouseDown)
            default: break
            }
            invalidate()
            return false
        }
        guard keyCode == key.code else {
            invalidate()
            if !flags.contains(key.flag) { isDown = false }
            return false
        }
        let raw = flags.rawValue
        let sides = raw & (key.leftMask | key.rightMask)
        let down = flags.contains(key.flag) && (sides == 0 || raw & key.rightMask != 0)
        if down {
            guard !isDown else { return false }
            // AppKit tracking loops may consume mouseUp; reconcile before a new tap.
            if physicalMouseButtons == 0 { buttonsDown.removeAll() }
            let hadObservedKeys = !keysDown.isEmpty
            // Clear stale observations for the NEXT tap. The current tap stays
            // blocked: current physical state may be newer than queued events.
            if let physicalKeysDown { keysDown = physicalKeysDown }
            isDown = true
            eligible = flags.intersection(Self.chordModifiers) == key.flag
                && raw & key.leftMask == 0 && !hadObservedKeys && keysDown.isEmpty && buttonsDown.isEmpty
                && (physicalMouseButtons ?? 0) == 0
            return false
        }
        let trigger = isDown && eligible && flags.intersection(Self.chordModifiers).isEmpty
        isDown = false
        eligible = false
        return trigger
    }
}

/// A cancelled permission request cannot start recording after a later request.
struct RecordingStartGate {
    private(set) var pending: UUID?
    var isPending: Bool { pending != nil }
    mutating func begin() -> UUID? {
        guard pending == nil else { return nil }
        let token = UUID()
        pending = token
        return token
    }
    mutating func finish(_ token: UUID) -> Bool {
        guard pending == token else { return false }
        pending = nil
        return true
    }
    mutating func cancel() { pending = nil }
}
