import Foundation
import Combine


@MainActor
final class HistoryRefinement: ObservableObject {
    static let shared = HistoryRefinement()

    struct Request: Equatable {
        let id: UUID
        let recordID: UUID
        let source: String
    }

    struct Candidate: Equatable {
        let request: Request
        let text: String
        let warnings: [String]
    }

    struct Notice: Equatable {
        let recordID: UUID
        let message: String
    }

    @Published private(set) var active: Request?
    @Published private(set) var candidate: Candidate?
    @Published private(set) var notice: Notice?
    @Published private(set) var cancelling = false
    private var task: Task<Void, Never>?

    nonisolated private static func requestRefinement(_ text: String) async -> EnhancementPreviewResult {
        await Transcriber.shared.enhancePreview(selection: text, operation: .smartDictation)
    }


    func start(
        record: DictationRecord,
        perform: @escaping @Sendable (String) async -> EnhancementPreviewResult = HistoryRefinement.requestRefinement
    ) {
        guard active == nil, !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let request = Request(id: UUID(), recordID: record.id, source: record.text)
        active = request
        cancelling = false
        notice = nil
        if candidate?.request.recordID != record.id || candidate?.request.source != record.text {
            candidate = nil
        }
        task = Task {
            let result: EnhancementPreviewResult
            if Task.isCancelled {
                result = .localFailure(original: request.source, operation: .smartDictation, errorCode: "cancelled")
            } else {
                result = await perform(request.source)
            }
            finish(request, result: result)
        }
    }

    private func finish(_ request: Request, result: EnhancementPreviewResult) {
        guard active?.id == request.id else { return }
        defer { active = nil; task = nil; cancelling = false }
        guard !cancelling else { return }
        guard result.readyForPreview, result.operation == .smartDictation,
              !result.candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let message = result.errorCode == "validation_failed"
                ? L("润色结果未通过内容检查，未修改原文；已有候选仍可核对。", "The refinement did not pass content checks. The original and any previous candidate are unchanged.")
                : EnhancementFailureMessage.message(code: result.errorCode ?? "preview_not_ready", stage: result.providerFailureStage)
            notice = Notice(recordID: request.recordID, message: message)
            return
        }
        candidate = Candidate(request: request, text: result.candidate, warnings: result.validationWarnings)
        if result.candidate == request.source {
            notice = Notice(recordID: request.recordID,
                            message: L("已请求润色，模型返回的文字没有变化。", "Refinement completed; the model returned unchanged text."))
        }
    }


    func cancel(recordID: UUID) {
        guard active?.recordID == recordID else { return }
        cancelling = true
        task?.cancel()
        notice = Notice(recordID: recordID,
                        message: L("已取消采用结果；已发出的服务请求可能仍在处理。", "The result will be ignored; an already-sent service request may still be processing."))
    }

    func canApply(to record: DictationRecord) -> Bool {
        guard active == nil, let candidate else { return false }
        return candidate.request.recordID == record.id && candidate.request.source == record.text
            && candidate.text != record.text
    }


    @discardableResult
    func apply(to store: DictationStore, recordID: UUID) -> Bool {
        guard let record = store.records.first(where: { $0.id == recordID }),
              canApply(to: record), let candidate else { return false }
        store.update(id: recordID, newText: candidate.text)
        self.candidate = nil
        notice = Notice(recordID: recordID,
                        message: L("已更新历史记录，未改动其他应用；可撤销或复制。", "History updated; other apps are unchanged. You can undo or copy the result."))
        return true
    }

    func dismiss(recordID: UUID) {
        if candidate?.request.recordID == recordID { candidate = nil }
        if notice?.recordID == recordID { notice = nil }
    }
}
