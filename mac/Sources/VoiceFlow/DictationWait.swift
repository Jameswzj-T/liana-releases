import Foundation

struct DictationDraft: Sendable, Equatable {
    let text: String
    let raw: String
}

struct DictationProgress: Sendable {
    let elapsed: Double
}



final class DictationWait: @unchecked Sendable {
    let runID: UUID
    private let lock = NSLock()
    private var savedDraft: DictationDraft?
    private var lastSequence = -1
    private var lastElapsed = -1.0
    private var backendPending = true
    private var interruptionIssued = false
    private var originalRequested = false
    private var completed = false
    private var failed = false

    init(runID: UUID) { self.runID = runID }

    static func normalizedID(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let compact = value.replacingOccurrences(of: "-", with: "").lowercased()
        guard compact.count == 32, compact.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return compact
    }

    func matches(_ value: Any?) -> Bool {
        Self.normalizedID(value) == Self.normalizedID(runID.uuidString)
    }

    func beginWaiting() { lock.lock(); backendPending = true; lock.unlock() }
    @discardableResult
    func endWaiting() -> Bool {
        lock.lock(); defer { lock.unlock() }
        backendPending = false
        return interruptionIssued
    }

    func receive(_ frame: [String: Any]) -> DictationProgress? {
        lock.lock(); defer { lock.unlock() }
        guard !completed, !originalRequested,
              frame["type"] as? String == "smart_progress",
              frame["stage"] as? String == "polishing", matches(frame["run_id"]),
              let sequence = frame["sequence"] as? Int, sequence == lastSequence + 1,
              let elapsed = frame["elapsed_seconds"] as? Double,
              elapsed.isFinite, elapsed >= 0, elapsed >= lastElapsed else { return nil }
        if sequence == 0 {
            guard let text = frame["local_text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let raw = frame["asr_raw"] as? String else { return nil }
            savedDraft = DictationDraft(text: text, raw: raw)
        } else {
            guard savedDraft != nil, frame["local_text"] == nil, frame["asr_raw"] == nil else { return nil }
        }
        lastSequence = sequence
        lastElapsed = elapsed
        return DictationProgress(elapsed: elapsed)
    }

    var draft: DictationDraft? { lock.lock(); defer { lock.unlock() }; return savedDraft }
    var choseOriginal: Bool { lock.lock(); defer { lock.unlock() }; return originalRequested }
    var connectionFailed: Bool { lock.lock(); defer { lock.unlock() }; return failed }
    func markConnectionFailed() { lock.lock(); failed = true; lock.unlock() }

    @discardableResult
    func requestOriginal(interrupt: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !completed, !originalRequested, savedDraft != nil else { return false }
        originalRequested = true

        if backendPending { interruptionIssued = true; interrupt() }
        return true
    }

    func cancel(interrupt: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        if backendPending { interruptionIssued = true; interrupt() }
    }

    func finish(text: String, raw: String) -> DictationDraft? {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { return nil }
        completed = true
        if originalRequested, let savedDraft { return savedDraft }
        return DictationDraft(text: text, raw: raw)
    }
}
