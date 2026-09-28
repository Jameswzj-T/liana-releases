import CoreGraphics






enum EscapeCancellationEvent {
    static let keyCode: Int64 = 53
    static let keyDownMask = CGEventMask(1) << CGEventType.keyDown.rawValue

    static func shouldCancel(type: CGEventType, keyCode: Int64) -> Bool {
        type == .keyDown && keyCode == Self.keyCode
    }
}
