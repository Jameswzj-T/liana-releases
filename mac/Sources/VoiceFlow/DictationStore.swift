import Foundation


struct DictationRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    var text: String        // var:记忆库里可编辑
    let durationSec: Double
    var raw: String?        // 原始转写(未润色);老记录没有=nil。编辑即学习按它记映射,匹配得上 raw 阶段纠错

    var chars: Int { text.count }

    var recoverableRaw: String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              raw != text else { return nil }
        return raw
    }

    init(text: String, durationSec: Double, raw: String = "", date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.text = text
        self.durationSec = durationSec
        self.raw = raw
    }
}


struct WeekStats {
    var count: Int
    var chars: Int
    var speakingSec: Double
    var savedSec: Double
}





private struct RecordSnapshot {
    let id: UUID
    let text: String
    let raw: String?
}


@MainActor
final class DictationStore: ObservableObject {
    static let shared = DictationStore()

    @Published private(set) var records: [DictationRecord] = []

    @Published private(set) var lastAudioURL: URL?
    @Published private(set) var lastAudioRecordID: UUID?
    @Published private(set) var canUndoLastChange = false
    @Published private(set) var storageError: String?
    private var unreadableHistory = false
    private let reportError: (String) -> Void

    private var lastChange: RecordSnapshot?



    static let typingCharsPerMin: Double = 80

    private let fileURL: URL

    init(fileURL explicitURL: URL? = nil, reportError: @escaping (String) -> Void = {
        Toast.show($0, duration: 6)
    }) {
        self.reportError = reportError
        let base = explicitURL?.deletingLastPathComponent() ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = explicitURL ?? base.appendingPathComponent("history.json")
        load()
    }



    @discardableResult
    func add(text: String, durationSec: Double, raw: String = "", audioURL: URL? = nil) -> UUID? {
        guard !text.isEmpty else { return nil }
        let record = DictationRecord(text: text, durationSec: durationSec, raw: raw)
        records.insert(record, at: 0)
        if let audioURL {
            TemporaryAudioFiles.shared.retain(audioURL)
            if let previous = lastAudioURL { TemporaryAudioFiles.shared.release(previous) }
            lastAudioURL = audioURL
            lastAudioRecordID = record.id
        }
        save()
        return record.id
    }

    func clearAll() {
        records = []
        if let previous = lastAudioURL { TemporaryAudioFiles.shared.release(previous) }
        lastAudioURL = nil
        lastAudioRecordID = nil
        lastChange = nil
        canUndoLastChange = false
        save()
    }



    func update(id: UUID, newText: String, raw: String? = nil) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        let old = records[idx]
        guard old.text != newText || (raw != nil && old.raw != raw) else { return }
        lastChange = RecordSnapshot(id: old.id, text: old.text, raw: old.raw)
        canUndoLastChange = true
        records[idx].text = newText
        if let raw { records[idx].raw = raw }
        save()
    }


    func canRetry(_ record: DictationRecord) -> Bool {
        guard record.id == lastAudioRecordID, let url = lastAudioURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }


    func undoLastChange() {
        guard let snapshot = lastChange,
              let idx = records.firstIndex(where: { $0.id == snapshot.id }) else { return }
        records[idx].text = snapshot.text
        records[idx].raw = snapshot.raw
        lastChange = nil
        canUndoLastChange = false
        save()
    }


    var thisWeek: WeekStats {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) ?? Date()
        let week = records.filter { $0.date >= start }
        let chars = week.reduce(0) { $0 + $1.chars }
        let speak = week.reduce(0) { $0 + $1.durationSec }
        let typingSec = Double(chars) / Self.typingCharsPerMin * 60
        return WeekStats(count: week.count, chars: chars, speakingSec: speak, savedSec: max(0, typingSec - speak))
    }


    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            records = try dec.decode([DictationRecord].self, from: Data(contentsOf: fileURL))
        } catch {
            unreadableHistory = true
            failStorage()
        }
    }

    private func failStorage() {
        storageError = L("历史记录未能保存或读取；本次文字仍在内存中，旧文件未覆盖。请及时复制文字。",
                         "History could not be saved or read. Copy your text before quitting; the old file was not replaced.")
        reportError(storageError!)
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        guard !unreadableHistory else { failStorage(); return }
        do {
            let data = try enc.encode(records)
            try data.write(to: fileURL, options: .atomic)
            storageError = nil
        } catch { failStorage() }
    }
}
