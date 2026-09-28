import Foundation


struct TextDeliveryPlan: Sendable {
    enum Part: Equatable, Sendable {
        case text(String)
        case lineBreak
        var utf16Count: Int {
            switch self {
            case .text(let text): return text.utf16.count
            case .lineBreak: return 1
            }
        }
    }

    let parts: [Part]
    let sourceUTF16Count: Int

    init(_ text: String, multiline: Bool) {
        sourceUTF16Count = text.utf16.count
        let lines = multiline ? text.components(separatedBy: "\n")
            : [text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)]
        var result: [Part] = []
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(.lineBreak) }
            result += Self.unicodeChunks(line).map(Part.text)
        }
        parts = result
    }



    static func unicodeChunks(_ text: String) -> [String] {
        var result: [String] = [], buffer = ""
        func append(_ unit: String) {
            if buffer.utf16.count + unit.utf16.count > 16 && !buffer.isEmpty {
                result.append(buffer)
                buffer = ""
            }
            buffer += unit
        }
        for character in text {
            let value = String(character)
            if value.utf16.count <= 16 {
                append(value)
            } else {
                for scalar in value.unicodeScalars { append(String(scalar)) }
            }
        }
        if !buffer.isEmpty { result.append(buffer) }
        return result
    }
}



@MainActor
final class TextDeliveryAttempt {
    enum Status: String {
        case submittedUnverified = "submitted_unverified"
        case targetChanged = "target_changed"
        case eventUnavailable = "event_unavailable"
        case alreadyAttempted = "already_attempted"
    }
    struct Receipt {
        let status: Status
        let submittedParts: Int
        let submittedUTF16: Int
        let submittedKeyEvents: Int
    }
    let id: UUID
    private var attempted = false

    init(id: UUID = UUID()) { self.id = id }

    func submit(
        _ plan: TextDeliveryPlan,
        stillCurrent: () -> Bool,
        emit: (TextDeliveryPlan.Part, Int) -> Bool
    ) -> Receipt {
        guard !attempted else {
            return Receipt(status: .alreadyAttempted, submittedParts: 0,
                           submittedUTF16: 0, submittedKeyEvents: 0)
        }
        attempted = true
        var submitted = 0, units = 0
        func receipt(_ status: Status) -> Receipt {
            Receipt(status: status, submittedParts: submitted,
                    submittedUTF16: units, submittedKeyEvents: submitted * 2)
        }
        for (index, part) in plan.parts.enumerated() {
            guard stillCurrent() else { return receipt(.targetChanged) }
            guard emit(part, index) else { return receipt(.eventUnavailable) }
            submitted += 1
            units += part.utf16Count
        }

        return receipt(.submittedUnverified)
    }
}
