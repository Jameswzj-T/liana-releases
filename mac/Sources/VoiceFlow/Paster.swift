import AppKit
import Carbon


@MainActor
enum Paster {

    private static func inputSourceIdentifier() -> String {
        guard let copied = TISCopyCurrentKeyboardInputSource() else { return "unknown" }
        let source = copied.takeRetainedValue()
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "unknown" }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    private static func traceIdentifier(_ value: String?) -> String {
        let result = (value ?? "unknown").replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return String(result.prefix(128))
    }

    struct DeliveryTarget {
        let pid: pid_t
        let bundleID: String?
        let element: AXUIElement?
        let multiline: Bool
    }

    static func captureTarget() -> DeliveryTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        var focused: CFTypeRef?
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        let status = AXUIElementCopyAttributeValue(ax, kAXFocusedUIElementAttribute as CFString, &focused)
        let element: AXUIElement? = status == .success && focused != nil
            && CFGetTypeID(focused!) == AXUIElementGetTypeID() ? (focused as! AXUIElement) : nil
        var role: CFTypeRef?
        if let element { AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) }
        return DeliveryTarget(pid: app.processIdentifier, bundleID: app.bundleIdentifier, element: element,
            multiline: role as? String == kAXTextAreaRole && AppStyleMap.multiline(for: app.bundleIdentifier))
    }

    static func targetMatches(_ target: DeliveryTarget?) -> Bool {
        targetMatches(target, current: captureTarget())
    }

    static func targetMatches(_ target: DeliveryTarget?, current: DeliveryTarget?) -> Bool {
        guard let target, let current, target.pid == current.pid else { return false }
        if let expected = target.element {
            guard let actual = current.element, CFEqual(expected, actual) else { return false }
        }
        return true
    }



    nonisolated static func textEvents(
        for part: TextDeliveryPlan.Part,
        source: CGEventSource?,
        makeEvent: (CGEventSource?, CGKeyCode, Bool) -> CGEvent? = {
            CGEvent(keyboardEventSource: $0, virtualKey: $1, keyDown: $2)
        }
    ) -> (CGEvent, CGEvent)? {
        let key: CGKeyCode = part == .lineBreak ? 36 : 0
        guard let down = makeEvent(source, key, true),
              let up = makeEvent(source, key, false) else { return nil }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            if case .text(let text) = part {
                let units = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
        }
        return (down, up)
    }



    static func deliver(
        _ text: String, to target: DeliveryTarget?, attempt: TextDeliveryAttempt,
        trace: (String) -> Void = { _ in },
        traceParts: Bool = false,
        currentTarget: @MainActor () -> DeliveryTarget? = captureTarget,
        postEvent: ((CGEvent) -> Void)? = nil,
        postToProcess: (CGEvent, pid_t) -> Void = { $0.postToPid($1) }
    ) -> TextDeliveryAttempt.Receipt {
        let plan = TextDeliveryPlan(text, multiline: target?.multiline ?? false)
        let id = attempt.id.uuidString.lowercased()
        let started = ProcessInfo.processInfo.systemUptime
        var focusMS = 0.0
        let transport = postEvent == nil ? "process" : "override"
        trace("delivery=\(id) begin pid=\(target?.pid ?? 0) app=\(traceIdentifier(target?.bundleID)) input_source=\(traceIdentifier(inputSourceIdentifier())) focused_element=\(target?.element != nil) multiline=\(target?.multiline ?? false) source_utf16=\(plan.sourceUTF16Count) planned_parts=\(plan.parts.count) transport=\(transport)")
        let result = attempt.submit(plan, stillCurrent: {
            let before = ProcessInfo.processInfo.systemUptime
            let matches = targetMatches(target, current: currentTarget())
            focusMS += (ProcessInfo.processInfo.systemUptime - before) * 1000
            return matches
        }, emit: { part, index in
            guard let target, target.pid > 0 else { return false }
            let source = CGEventSource(stateID: .combinedSessionState)
            let key: CGKeyCode = part == .lineBreak ? 36 : 0
            guard let (down, up) = textEvents(for: part, source: source) else { return false }



            if let postEvent {
                postEvent(down)
                postEvent(up)
            } else {
                postToProcess(down, target.pid)
                postToProcess(up, target.pid)
            }
            if traceParts {
                trace("delivery=\(id) part=\(index) kind=\(key == 36 ? "newline" : "unicode") utf16=\(part.utf16Count) events_submitted=2")
            }
            return true
        })
        let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        trace("delivery=\(id) end status=\(result.status.rawValue) parts_submitted=\(result.submittedParts) utf16_submitted=\(result.submittedUTF16) key_events_submitted=\(result.submittedKeyEvents) focus_ms=\(Int(focusMS)) elapsed_ms=\(elapsedMS)")
        return result
    }


    struct ClipboardSnapshot: Sendable {
        fileprivate let items: [[String: Data]]
        let changeCount: Int
    }

    struct ClipboardPasteReceipt: Sendable {
        let backup: ClipboardSnapshot

        let ownedChangeCount: Int
    }

    // Selected-text previews publish a copy only. The user chooses where to paste.
    static func copyCandidate(
        _ text: String,
        on pasteboard: NSPasteboard = .general,
        writeText: (NSPasteboard, String) -> Bool = { $0.setString($1, forType: .string) }
    ) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let owned = pasteboard.clearContents()
        guard pasteboard.changeCount == owned, writeText(pasteboard, text),
              pasteboard.changeCount == owned else { return false }
        return true
    }

    nonisolated static func commandEvents(_ key: CGKeyCode) -> (CGEvent, CGEvent)? {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        return (down, up)
    }


    static func paste(
        _ text: String,
        on pb: NSPasteboard = .general,
        stillCurrent: () -> Bool,
        makeEvents: (CGKeyCode) -> (CGEvent, CGEvent)? = commandEvents,
        readItems: (NSPasteboard) -> [NSPasteboardItem]? = { $0.pasteboardItems },
        readData: (NSPasteboardItem, NSPasteboard.PasteboardType) -> Data? = { $0.data(forType: $1) },
        writeText: (NSPasteboard, String) -> Bool = { $0.setString($1, forType: .string) },
        postEvent: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    ) -> ClipboardPasteReceipt? {
        guard !text.isEmpty, let (down, up) = makeEvents(0x09), stillCurrent(),
              let backup = snapshotClipboard(pb, readItems: readItems, readData: readData), stillCurrent(),
              pb.changeCount == backup.changeCount else { return nil }
        let owned = pb.clearContents()
        guard pb.changeCount == owned, writeText(pb, text),
              pb.changeCount == owned, stillCurrent(), pb.changeCount == owned else {
            restoreClipboard(backup, ifUnchangedSince: owned, to: pb)
            return nil
        }
        postEvent(down)
        postEvent(up)
        return ClipboardPasteReceipt(backup: backup, ownedChangeCount: owned)
    }



    static func copySelection(
        on pb: NSPasteboard = .general,
        stillCurrent: () -> Bool,
        makeEvents: (CGKeyCode) -> (CGEvent, CGEvent)? = commandEvents,
        readItems: (NSPasteboard) -> [NSPasteboardItem]? = { $0.pasteboardItems },
        readData: (NSPasteboardItem, NSPasteboard.PasteboardType) -> Data? = { $0.data(forType: $1) },
        readText: (NSPasteboard) -> String? = { $0.string(forType: .string) },
        postEvent: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    ) -> String? {
        guard let (down, up) = makeEvents(0x08), stillCurrent(),
              let backup = snapshotClipboard(pb, readItems: readItems, readData: readData), stillCurrent(),
              pb.changeCount == backup.changeCount else { return nil }
        postEvent(down)
        postEvent(up)
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            let copiedCount = pb.changeCount
            if copiedCount != backup.changeCount {
                let text = readText(pb)
                guard pb.changeCount == copiedCount else { return nil }
                restoreClipboard(backup, ifUnchangedSince: copiedCount, to: pb)
                return text
            }
            usleep(15_000)
        }
        return nil
    }


    static func snapshotClipboard(
        _ pasteboard: NSPasteboard = .general,
        readItems: (NSPasteboard) -> [NSPasteboardItem]? = { $0.pasteboardItems },
        readData: (NSPasteboardItem, NSPasteboard.PasteboardType) -> Data? = { $0.data(forType: $1) }
    ) -> ClipboardSnapshot? {
        let before = pasteboard.changeCount

        guard let source = readItems(pasteboard) else { return nil }
        var items: [[String: Data]] = []
        for item in source {
            var saved: [String: Data] = [:]
            for type in item.types {
                guard let data = readData(item, type) else { return nil }
                saved[type.rawValue] = data
            }
            items.append(saved)
        }
        guard pasteboard.changeCount == before else { return nil }
        return ClipboardSnapshot(items: items, changeCount: before)
    }



    @discardableResult
    static func restoreClipboard(
        _ snapshot: ClipboardSnapshot?,
        ifUnchangedSince expected: Int,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard let snapshot, pasteboard.changeCount == expected else { return false }
        var restored: [NSPasteboardItem] = []
        for saved in snapshot.items {
            let item = NSPasteboardItem()
            for (rawType, data) in saved {
                guard item.setData(data, forType: NSPasteboard.PasteboardType(rawType)) else { return false }
            }
            restored.append(item)
        }
        guard pasteboard.changeCount == expected else { return false }
        let owned = pasteboard.clearContents()
        guard pasteboard.changeCount == owned else { return false }
        return restored.isEmpty || pasteboard.writeObjects(restored)
    }










    nonisolated static func type(_ text: String, multiline: Bool = false) {
        guard !text.isEmpty else { return }
        guard multiline, text.contains("\n") else {



            typeUnicode(text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression))
            return
        }


        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if i > 0 { pressReturn() }
            let flat = line.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            if !flat.isEmpty { typeUnicode(flat) }
        }
    }


    private nonisolated static func typeUnicode(_ s: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for chunk in TextDeliveryPlan.unicodeChunks(s) {
            guard let (down, up) = textEvents(for: .text(chunk), source: src) else { return }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }


    private nonisolated static func pressReturn() {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let (down, up) = textEvents(for: .lineBreak, source: src) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
