import AppKit
import SwiftUI


struct HistoryView: View {
    @ObservedObject var store = DictationStore.shared
    var onBack: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.Palette.bgElevated))
                }.buttonStyle(.plain)
                Text(L("记忆库", "History")).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.Palette.textPrimary)
                Text(L("· \(store.records.count) 条", "· \(store.records.count)")).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                if store.canUndoLastChange {
                    Button {
                        store.undoLastChange()
                        Toast.show(L("已撤销最近一次记录修改", "Undid the latest record edit"))
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                            Text(L("撤销记录修改", "Undo record edit"))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Theme.Palette.bgElevated))
                    }
                    .buttonStyle(.plain)
                    .help(L("只恢复 Liana 记忆库，不撤销已粘贴到其他 app 的文字", "Restores Liana history only; does not undo text already pasted elsewhere"))
                }
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)

            if store.records.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 30)).foregroundStyle(Theme.Palette.textTertiary)
                    Text(L("还没有记录。按热键说一句试试。", "Nothing here yet. Press your hotkey and say something.")).foregroundStyle(Theme.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.records) { HistoryRow(record: $0) }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
        }
    }
}

struct HistoryRow: View {
    let record: DictationRecord
    @ObservedObject private var store = DictationStore.shared
    @ObservedObject private var refinement = HistoryRefinement.shared
    @State private var editing = false
    @State private var draft = ""
    @State private var learned = ""        // 改完保存的正确写法，短暂提示；不冒充已生成固定错→对规则
    @State private var retryDraft: String?
    @State private var retryRaw = ""
    @State private var retrying = false
    @State private var showingRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if editing {
                TextEditor(text: $draft)
                    .font(.system(size: 14)).scrollContentBackground(.hidden)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .frame(minHeight: 64)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.Palette.bgElevated))
                HStack {
                    Spacer()
                    Button(L("取消", "Cancel")) { editing = false }.buttonStyle(.plain).foregroundStyle(Theme.Palette.textSecondary)
                    Button(L("保存", "Save")) { save() }.buttonStyle(.plain).foregroundStyle(Theme.Palette.accent).fontWeight(.semibold)
                }.font(.system(size: 12))
            } else {
                Text(record.text).font(.system(size: 14.5)).lineSpacing(2)
                    .textSelection(.enabled).foregroundStyle(Theme.Palette.textPrimary)
                HStack(spacing: 8) {
                    Text(record.date, style: .relative).foregroundStyle(Theme.Palette.textTertiary)
                    Text(L("· \(record.chars) 字", "· \(record.chars) chars")).foregroundStyle(Theme.Palette.textTertiary)
                    if !learned.isEmpty {
                        Text(L("✓ 已保存写法：\(learned)", "✓ Saved spelling: \(learned)")).foregroundStyle(Theme.Palette.accent)
                    }
                    Spacer()
                    Button { draft = record.text; editing = true } label: {
                        Image(systemName: "pencil").font(.system(size: 13)).foregroundStyle(Theme.Palette.textTertiary)
                    }.buttonStyle(.plain).help(L("编辑", "Edit"))
                    Button {
                        guard let current = store.records.first(where: { $0.id == record.id }) else { return }
                        refinement.start(record: current)
                    } label: {
                        Label(refinement.active?.recordID == record.id
                              ? L("润色中…", "Refining…") : L("重新润色", "Refine again"),
                              systemImage: "sparkles")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Palette.accent)
                    .disabled(retrying || refinement.active != nil)
                    .help(L("将当前这段文字交给所选云端文字模型重新润色；需要启用文字增强，结果先预览，不重新识别录音", "Refine this text with the selected cloud text model. Requires text enhancement. Preview only; audio is not re-transcribed."))
                    if store.canRetry(record) {
                        Button(action: retry) {
                            HStack(spacing: 4) {
                                Image(systemName: retrying ? "hourglass" : "arrow.clockwise")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(retrying ? L("重新转写中…", "Transcribing again…") : L("重新转写录音", "Re-transcribe audio"))
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(retrying ? Theme.Palette.accent : Theme.Palette.textSecondary)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Capsule().fill(Theme.Palette.bgElevated))
                        }
                        .buttonStyle(.plain)
                        .disabled(retrying || refinement.active != nil)
                        .help(L("用本地转写模型重新识别最近一段录音，不是重新润色；结果先预览，不自动覆盖", "Re-transcribe the latest audio locally, without cloud text refinement. Preview only; nothing is replaced automatically."))
                    }
                    if record.recoverableRaw != nil {
                        Button { showingRaw.toggle() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showingRaw ? "eye.slash" : "eye")
                                Text(showingRaw
                                     ? L("收起原文", "Hide raw")
                                     : L("查看原文", "View raw"))
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help(L("查看自动整理前的原始转写", "View the raw transcript before refinement"))
                    }
                    CopyIconButton(text: record.text)
                }
                .font(.system(size: 11.5))
                if refinement.active?.recordID == record.id {
                    HStack {
                        Text(refinement.cancelling
                             ? L("等待已发请求结束，结果不会采用", "Waiting for the sent request to finish; its result will be ignored")
                             : L("正在重新润色文字；不会重复插入其他应用", "Refining text; nothing will be inserted into other apps"))
                        Spacer()
                        Button(L("取消", "Cancel")) { refinement.cancel(recordID: record.id) }
                            .disabled(refinement.cancelling)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textSecondary)
                }
                if let notice = refinement.notice, notice.recordID == record.id {
                    Text(notice.message).font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                if let candidate = refinement.candidate, candidate.request.recordID == record.id {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("重新润色结果（尚未采用）", "Refinement result (not applied)"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Text(candidate.text).font(.system(size: 14.5)).lineSpacing(2)
                            .textSelection(.enabled).foregroundStyle(Theme.Palette.textPrimary)
                        if !candidate.warnings.isEmpty {
                            Text(L("结果有内容变化提示，请核对数字、专名和原意。", "Content changes were flagged. Check numbers, names, and meaning."))
                                .font(.system(size: 12)).foregroundStyle(Theme.Palette.textSecondary)
                        }
                        if candidate.request.source != record.text {
                            Text(L("记录已改变，不能用旧候选覆盖；仍可复制。", "This record changed; the old candidate cannot replace it, but can still be copied."))
                                .font(.system(size: 12)).foregroundStyle(Theme.Palette.textSecondary)
                        }
                        HStack(spacing: 10) {
                            Button(L("更新历史记录", "Update history")) {
                                refinement.apply(to: store, recordID: record.id)
                            }
                            .disabled(!refinement.canApply(to: record))
                            .foregroundStyle(Theme.Palette.accent)
                            Button(L("不采用", "Dismiss")) { refinement.dismiss(recordID: record.id) }
                            CopyIconButton(text: candidate.text, size: 12)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.Palette.bgElevated))
                }
                if showingRaw, let raw = record.recoverableRaw {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("原始转写（自动整理前）", "Raw transcript (before refinement)"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.Palette.textTertiary)
                            Spacer()
                            CopyIconButton(text: raw, size: 12)
                        }
                        Text(raw)
                            .font(.system(size: 13.5))
                            .lineSpacing(2)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.Palette.bgElevated))
                }
                if let retryDraft {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("本地重新转写结果（未经云端润色，尚未采用）", "Local re-transcription (not cloud-refined, not applied)"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Text(retryDraft)
                            .font(.system(size: 14.5)).lineSpacing(2)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .textSelection(.enabled)
                        HStack(spacing: 10) {
                            Button(L("采用这次结果", "Use this result")) { adoptRetry(retryDraft) }
                                .buttonStyle(.plain).foregroundStyle(Theme.Palette.accent).fontWeight(.semibold)
                            Button(L("不采用", "Dismiss")) { self.retryDraft = nil }
                                .buttonStyle(.plain).foregroundStyle(Theme.Palette.textSecondary)
                            CopyIconButton(text: retryDraft, size: 12)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.Palette.bgElevated))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(16)
        .onDisappear { refinement.cancel(recordID: record.id) }
    }

    private func save() {
        editing = false
        guard draft != record.text, !draft.isEmpty else { return }
        let old = record.text
        DictationStore.shared.update(id: record.id, newText: draft)
        Task {

            let terms = await Transcriber.shared.learn(old: old, new: draft, raw: record.raw ?? "")
            guard !terms.isEmpty else { return }
            await MainActor.run { learned = terms.joined(separator: "、") }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { learned = "" }
        }
    }

    private func retry() {
        guard !retrying, refinement.active == nil, store.canRetry(record),
              let url = store.lastAudioURL else { return }
        TemporaryAudioFiles.shared.retain(url)
        retrying = true
        retryDraft = nil
        Task {
            defer { TemporaryAudioFiles.shared.release(url) }
            let result = await Transcriber.shared.transcribe(path: url.path)
            let raw = await Transcriber.shared.lastRaw
            await MainActor.run {
                retrying = false
                if result.isEmpty {
                    Toast.show(L("重新转写没有得到结果，原文字未改变。", "Re-transcription returned no text; the original is unchanged."), duration: 3)
                } else {
                    retryRaw = raw
                    retryDraft = result
                }
            }
        }
    }

    private func adoptRetry(_ text: String) {
        DictationStore.shared.update(id: record.id, newText: text, raw: retryRaw.isEmpty ? nil : retryRaw)
        retryDraft = nil
        Toast.show(L("已更新历史中的重新转写结果，未改动其他应用；可点“撤销记录修改”。", "Re-transcription applied to history only; other apps are unchanged. Use Undo record edit if needed."))
    }

}


struct CopyIconButton: View {
    let text: String
    var size: CGFloat = 13
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: size, weight: copied ? .bold : .regular))
                .foregroundStyle(copied ? Theme.Palette.accent : Theme.Palette.textTertiary)
                .frame(width: 20, height: 18)   // 固定占位:doc.on.doc↔checkmark 宽度不同,不锁死会让整行/整卡片"缩一下"
        }
        .buttonStyle(.plain)
        .help(copied ? L("已复制", "Copied") : L("复制", "Copy"))
    }
}
