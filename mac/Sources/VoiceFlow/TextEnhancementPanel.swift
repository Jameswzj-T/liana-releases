import AppKit
import SwiftUI


@MainActor
final class TextEnhancementPanelModel: ObservableObject {
    enum Phase: Equatable {
        case preparing
        case recording
        case processing
        case idle
    }


    enum SourceMode: String, CaseIterable, Identifiable {
        case current
        case original

        var id: String { rawValue }
    }

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var original = ""
    @Published private(set) var candidate: String?
    @Published private(set) var activeOperation: EnhancementOperation = .instruction
    @Published private(set) var recognizedInstruction: String?
    @Published private(set) var result: EnhancementPreviewResult?
    @Published private(set) var lastCandidateChanged: Bool?
    @Published private(set) var candidateOperation: EnhancementOperation?
    @Published private(set) var candidateInstruction: String?
    @Published var sourceMode: SourceMode = .current
    @Published private(set) var lastRequestSourceMode: SourceMode?

    private var processingSource = ""
    private var processingSourceMode: SourceMode = .original

    var effectiveSourceMode: SourceMode {
        candidate == nil || sourceMode == .original ? .original : .current
    }
    var requestSource: String {
        effectiveSourceMode == .current ? (candidate ?? original) : original
    }
    var canAccept: Bool { candidate != nil && candidate != original && phase == .idle }
    var canStartVoice: Bool { phase == .idle }

    func reset(original: String) {
        self.original = original
        candidate = nil
        activeOperation = .instruction
        recognizedInstruction = nil
        result = nil
        lastCandidateChanged = nil
        candidateOperation = nil
        candidateInstruction = nil
        sourceMode = .current
        lastRequestSourceMode = nil
        processingSource = ""
        processingSourceMode = .original
        phase = .preparing
    }

    func beginVoice() {
        activeOperation = .instruction
        recognizedInstruction = nil
        result = nil
        lastCandidateChanged = nil
        phase = .preparing
    }

    func markRecording() {
        guard phase == .preparing else { return }
        phase = .recording
    }

    func beginProcessing(_ operation: EnhancementOperation) {
        processingSource = requestSource
        processingSourceMode = effectiveSourceMode
        activeOperation = operation
        result = nil
        lastCandidateChanged = nil
        if operation != .instruction { recognizedInstruction = nil }
        phase = .processing
    }

    func finish(_ result: EnhancementPreviewResult) {
        self.result = result
        if let instruction = result.instruction, !instruction.isEmpty {
            recognizedInstruction = instruction
        }
        if result.readyForPreview {
            lastCandidateChanged = result.candidate != processingSource
            lastRequestSourceMode = processingSourceMode
            candidate = result.candidate
            candidateOperation = result.operation
            candidateInstruction = result.operation == .instruction ? result.instruction : nil
        } else {
            lastCandidateChanged = nil
        }
        processingSource = ""
        phase = .idle
    }

    func fail(_ code: String) {
        finish(.localFailure(original: requestSource, operation: activeOperation, errorCode: code))
    }
}


@MainActor
final class TextEnhancementPanel: NSObject, NSWindowDelegate {
    static let shared = TextEnhancementPanel()

    private let panelWidth: CGFloat = 700
    private let minimumPanelHeight: CGFloat = 560
    private let maximumPanelHeight: CGFloat = 900

    let model = TextEnhancementPanelModel()
    let meter = HUDModel()

    private var panel: NSPanel?
    private var priorApp: NSRunningApplication?
    private var onDismiss: (() -> Void)?
    private var onVoiceAction: (() -> Void)?
    private var onQuickAction: ((EnhancementOperation) -> Void)?

    var requestSource: String { model.requestSource }
    var canStartVoice: Bool { model.canStartVoice }

    func show(
        selection: String,
        hotkeyDisplay: String,
        onVoiceAction: @escaping () -> Void,
        onQuickAction: @escaping (EnhancementOperation) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        priorApp = NSWorkspace.shared.frontmostApplication
        self.onVoiceAction = onVoiceAction
        self.onQuickAction = onQuickAction
        self.onDismiss = onDismiss
        model.reset(original: selection)
        meter.reset()
        meter.active = true

        if panel == nil { panel = makePanel() }
        panel?.contentViewController = NSHostingController(
            rootView: TextEnhancementView(
                model: model,
                meter: meter,
                hotkeyDisplay: hotkeyDisplay,
                onVoiceAction: { [weak self] in self?.onVoiceAction?() },
                onQuickAction: { [weak self] operation in self?.onQuickAction?(operation) },
                onAccept: { [weak self] candidate in self?.accept(candidate) },
                onCancel: { [weak self] in self?.cancel() }
            )
        )
        resizePanelToFit(center: true, animated: false)


        panel?.orderFrontRegardless()
    }

    func beginVoice() {
        model.beginVoice()
        meter.reset()
        meter.active = true
        resizePanelToFit(animated: true)
    }

    func markRecording() { model.markRecording() }
    func push(_ rms: Float, _ bands: [Float]) { meter.push(rms, bands) }

    func beginProcessing(_ operation: EnhancementOperation) {
        meter.active = false
        model.beginProcessing(operation)
        resizePanelToFit(animated: true)
    }

    func finish(_ result: EnhancementPreviewResult) {
        meter.active = false
        model.finish(result)
        resizePanelToFit(animated: true)
    }

    func fail(_ code: String) {
        meter.active = false
        model.fail(code)
        resizePanelToFit(animated: true)
    }

    func cancel() {
        guard onDismiss != nil else { return }
        let prior = priorApp
        meter.active = false
        panel?.orderOut(nil)
        finishSession()
        if let prior, prior.bundleIdentifier != Bundle.main.bundleIdentifier {
            prior.activate(options: [])
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel()
        return false
    }

    private func accept(_ candidate: String) {
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              onDismiss != nil, model.canAccept else { return }
        meter.active = false
        guard Paster.copyCandidate(candidate) else {
            Toast.show(L("复制失败，候选仍保留；原应用文字未改动。", "Copy failed. Your candidate is still here; the original app was not changed."), duration: 5)
            return
        }
        panel?.orderOut(nil)
        finishSession()
        Toast.show(L("候选已复制。请回到原应用，确认选区后按 ⌘V 粘贴。", "Candidate copied. Return to your app, check the selection, then press ⌘V to paste."), duration: 5)
    }

    private func finishSession() {
        priorApp = nil
        onVoiceAction = nil
        onQuickAction = nil
        let completion = onDismiss
        onDismiss = nil
        completion?()
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: minimumPanelHeight),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .aqua)
        p.backgroundColor = NSColor(
            red: 0xF5 / 255.0,
            green: 0xF1 / 255.0,
            blue: 0xE8 / 255.0,
            alpha: 1
        )
        p.delegate = self
        return p
    }


    private func resizePanelToFit(center: Bool = false, animated: Bool) {
        guard let panel else { return }
        let target = preferredContentSize(for: panel)
        if center {
            panel.setContentSize(target)
            panel.center()
            return
        }

        let oldFrame = panel.frame
        var newFrame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: target))

        newFrame.origin.x = oldFrame.midX - newFrame.width / 2
        newFrame.origin.y = oldFrame.maxY - newFrame.height

        if let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            let inset: CGFloat = 12
            newFrame.origin.x = min(max(newFrame.origin.x, visible.minX + inset), visible.maxX - inset - newFrame.width)
            newFrame.origin.y = min(max(newFrame.origin.y, visible.minY + inset), visible.maxY - inset - newFrame.height)
        }
        panel.setFrame(newFrame, display: true, animate: animated)
    }

    private func preferredContentSize(for panel: NSPanel) -> NSSize {
        let visibleHeight = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? maximumPanelHeight + 60
        let screenLimitedMaximum = max(500, min(maximumPanelHeight, visibleHeight - 48))
        let minimum = min(minimumPanelHeight, screenLimitedMaximum)

        let originalCard = estimatedCardHeight(model.original)
        let candidateCard = model.candidate.map(estimatedCardHeight) ?? 58
        let sourceChooser: CGFloat = model.candidate == nil ? 0 : 46
        let statusLines = CGFloat([
            model.candidate != nil && model.lastCandidateChanged != nil,
            model.candidate != nil && !(model.result?.validationWarnings.isEmpty ?? true),
            model.candidate != nil && model.result?.errorCode != nil,
        ].filter { $0 }.count)

        let fixedChrome: CGFloat = 322 + sourceChooser
        let previewSpacing: CGFloat = 42 + statusLines * 24
        let estimated = fixedChrome + originalCard + candidateCard + previewSpacing
        return NSSize(width: panelWidth, height: max(minimum, min(screenLimitedMaximum, estimated)))
    }

    private func estimatedCardHeight(_ text: String) -> CGFloat {
        let textWidth = panelWidth - 74
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13.5)]
        )

        return max(82, ceil(bounds.height) + 45)
    }
}

private struct TextEnhancementView: View {
    @ObservedObject var model: TextEnhancementPanelModel
    @ObservedObject var meter: HUDModel
    let hotkeyDisplay: String
    let onVoiceAction: () -> Void
    let onQuickAction: (EnhancementOperation) -> Void
    let onAccept: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            voiceLane
            if model.candidate != nil {
                sourceControl
            }
            quickActions
            ScrollView(.vertical) {
                previewArea
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            footer
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Palette.bgBase)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("告诉 Liana 怎么改", "Tell Liana how to rewrite it"))
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Label(L("复制后手动粘贴", "Copy, then paste yourself"), systemImage: "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.accent)
            }
            Text(L(
                "直接说出要求，或使用快捷方式。指令音频留在本机；处理时只发送选中文字和指令文字。",
                "Speak an instruction or use a shortcut. Audio stays on this Mac; only the selected text and instruction text are sent for processing."
            ))
            .font(.system(size: 12))
            .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private var voiceLane: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Theme.Palette.bgElevated)
                    EqualizerBars(levels: meter.levels, active: meter.active)
                        .frame(width: 76, height: 32)
                }
                .frame(width: 96, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(voiceTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(voiceSubtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if model.phase == .processing {
                    ProgressView().controlSize(.small)
                } else if model.phase == .recording {
                    Button(L("完成", "Done"), action: onVoiceAction)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accentInk)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Theme.Palette.accent))
                } else if model.canStartVoice {
                    Button(L("再说一个要求", "Speak another"), action: onVoiceAction)
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Theme.Palette.accent.opacity(0.10)))
                }
            }

            Text(L(
                "例如：“翻译成英文” · “改得更自然” · “变成友好语气” · “整理成邮件”",
                "Try: “Translate to English” · “Make it natural” · “Use a friendly tone” · “Format it as an email”"
            ))
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.Palette.bgSurface))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .strokeBorder(model.phase == .recording ? Theme.Palette.accent : Theme.Palette.borderSubtle)
        )
    }

    private var quickActions: some View {
        HStack(spacing: Theme.Space.s) {
            Text(L("快捷方式", "Shortcuts"))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)

            ForEach(EnhancementOperation.quickActions) { operation in
                let isLatestCompletedAction = model.phase == .idle
                    && model.result?.readyForPreview == true
                    && model.activeOperation == operation
                Button { onQuickAction(operation) } label: {
                    Label(operation.title, systemImage: operation.symbol)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(isLatestCompletedAction ? Theme.Palette.accent : Theme.Palette.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(
                                (model.activeOperation == operation && model.phase == .processing)
                                    || isLatestCompletedAction
                                    ? Theme.Palette.accent.opacity(0.12)
                                    : Theme.Palette.bgElevated
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(model.phase == .processing)
                .accessibilityLabel(operation.title)
            }
            Spacer(minLength: 0)
        }
    }

    private var sourceControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.m) {
                Label(L("下一次修改基于", "Next request uses"), systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer(minLength: 8)
                Picker("", selection: $model.sourceMode) {
                    Text(L("当前版本", "Current version"))
                        .tag(TextEnhancementPanelModel.SourceMode.current)
                    Text(L("最初原文", "Original"))
                        .tag(TextEnhancementPanelModel.SourceMode.original)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 224)
                .disabled(model.phase == .processing)
            }

            Text(sourceModeExplanation)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.Palette.bgElevated)
        )
    }

    private var previewArea: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            TextCard(label: L("最初原文", "Original"), text: model.original, emphasized: false)

            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                if let instruction = model.candidateInstruction {
                    Text(L("当前版本 · 指令：\(instruction)", "Current version · Instruction: \(instruction)"))
                        .lineLimit(1)
                } else {
                    Text(L("当前版本", "Current version"))
                }
                Spacer(minLength: 8)
                if model.lastRequestSourceMode != nil {
                    Text(L("基于\(lastRequestSourceLabel)", "Based on \(lastRequestSourceLabel)"))
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.Palette.textTertiary)

            if let candidate = model.candidate {
                TextCard(label: candidateLabel, text: candidate, emphasized: true)

                if let completionMessage {
                    Label(completionMessage, systemImage: model.lastCandidateChanged == true ? "checkmark.circle" : "equal.circle")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(model.lastCandidateChanged == true ? Theme.Palette.accent : Theme.Palette.textSecondary)
                }

                if let validationWarningMessage {
                    Label(validationWarningMessage, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.warning)
                }
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(Theme.Palette.bgSurface)
                    .overlay(alignment: .leading) {
                        HStack(spacing: 9) {
                            if model.phase == .processing { ProgressView().controlSize(.small) }
                            Text(candidatePlaceholder)
                                .font(.system(size: 12.5))
                                .foregroundStyle(errorMessage == nil ? Theme.Palette.textTertiary : Theme.Palette.danger)
                        }
                        .padding(14)
                    }
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.Palette.borderSubtle))
                    .frame(minHeight: 58)
            }

            if model.candidate != nil, let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Palette.danger)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.m) {
            if let result = model.result, result.readyForPreview {
                let total = result.usage?.totalTokens
                Text(total.map {
                    L("耗时 \(result.latencyMS) ms · \($0) tokens", "\(result.latencyMS) ms · \($0) tokens")
                } ?? L("耗时 \(result.latencyMS) ms", "\(result.latencyMS) ms"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Label(L("复制不会改动原文", "Copy leaves the original unchanged"), systemImage: "doc.on.doc")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.Palette.textTertiary)
            Spacer()
            Button(L("取消", "Cancel"), action: onCancel)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.textSecondary)
                .keyboardShortcut(.cancelAction)
            Button(acceptButtonTitle) {
                if let candidate = model.candidate { onAccept(candidate) }
            }
            .buttonStyle(.plain)
            .fontWeight(.semibold)
            .foregroundStyle(model.canAccept ? Theme.Palette.accentInk : Theme.Palette.textTertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(model.canAccept ? Theme.Palette.accent : Theme.Palette.bgElevated))
            .disabled(!model.canAccept)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .font(.system(size: 13))
    }

    private var voiceTitle: String {
        switch model.phase {
        case .preparing:
            return L("正在打开麦克风…", "Starting the microphone…")
        case .recording:
            return L("说出你想怎么改", "Say how you want it rewritten")
        case .processing:
            return model.activeOperation == .instruction
                ? L("正在听懂并生成候选…", "Understanding and generating a candidate…")
                : L("正在生成候选…", "Generating a candidate…")
        case .idle:
            if let instruction = model.recognizedInstruction {
                return L("已听到：“\(instruction)”", "Heard: “\(instruction)”")
            }
            return L("还可以继续调整", "You can refine it again")
        }
    }

    private var voiceSubtitle: String {
        switch model.phase {
        case .preparing:
            return L("麦克风就绪后会响一声", "A sound confirms when the microphone is ready")
        case .recording:
            return L("再次按 \(hotkeyDisplay) 或点“完成”", "Press \(hotkeyDisplay) again or click Done")
        case .processing:
            return L("原文仍未改变", "The original is still unchanged")
        case .idle:
            return L("按 \(hotkeyDisplay) 再说一个要求，或选下面的快捷方式", "Press \(hotkeyDisplay) to speak again, or choose a shortcut below")
        }
    }

    private var candidateLabel: String {
        (model.candidateOperation ?? .instruction) == .instruction
            ? L("语音指令候选", "Voice instruction candidate")
            : (model.candidateOperation?.title ?? L("候选", "Candidate"))
    }

    private var sourceModeExplanation: String {
        switch model.sourceMode {
        case .current:
            return L("接着刚生成的版本继续改，适合“再短一点”“再正式一点”。", "Continue from the generated version, useful for requests such as “shorter” or “more formal”.")
        case .original:
            return L("忽略当前候选，从最初选中文字重新生成一个版本。", "Ignore the current candidate and generate again from the original selection.")
        }
    }

    private var lastRequestSourceLabel: String {
        switch model.lastRequestSourceMode {
        case .current:
            return L("上一版本", "the previous version")
        case .original, .none:
            return L("最初原文", "the original")
        }
    }

    private var acceptButtonTitle: String {
        if model.candidate != nil, model.result?.readyForPreview == false {
            return L("复制上一候选", "Copy previous candidate")
        }
        return L("复制候选", "Copy candidate")
    }

    private var completionMessage: String? {
        guard model.result?.readyForPreview == true,
              let changed = model.lastCandidateChanged else { return nil }
        let action = model.activeOperation == .instruction
            ? L("语音要求", "voice instruction")
            : model.activeOperation.title
        if changed {
            return L(
                "已基于\(lastRequestSourceLabel)执行“\(action)”，生成当前版本",
                "A new version was generated from \(lastRequestSourceLabel) using \(action)"
            )
        }
        return L(
            "已基于\(lastRequestSourceLabel)执行“\(action)”，文字没有变化",
            "The \(action) was applied to \(lastRequestSourceLabel); the text was unchanged"
        )
    }

    private var candidatePlaceholder: String {
        switch model.phase {
        case .preparing:
            return L("准备听你的修改要求…", "Getting ready to hear your instruction…")
        case .recording:
            return L("正在听你的修改要求；再次按热键后开始处理。", "Listening to your instruction; press the hotkey again to process it.")
        case .processing:
            return L("正在生成候选，原文不会被修改…", "Generating a candidate; the original remains unchanged…")
        case .idle:
            if let errorMessage { return errorMessage }
            return L("说出要求或选择快捷方式后，候选会显示在这里。", "Speak an instruction or choose a shortcut to generate a candidate.")
        }
    }

    private var errorMessage: String? {
        guard let code = model.result?.errorCode else { return nil }
        switch code {
        case "no_polish_key", "missing_credentials", "provider_auth_failed":
            return L("凭据不可用。请到设置检查 API Key；原文没有改变。", "The credential is unavailable. Check the API key in Settings; the original is unchanged.")
        case "text_enhancement_disabled":
            return L("请先在设置中启用文字增强；原文没有改变。", "Enable text enhancement in Settings first; the original is unchanged.")
        case "validation_failed":
            let action = model.activeOperation == .instruction
                ? L("语音要求", "voice instruction")
                : model.activeOperation.title
            let reason = validationReason(model.result?.validationIssues ?? [])
            if model.candidate != nil {
                return L(
                    "“\(action)”的新结果触发了保护（\(reason)），已拦截；上一个候选仍可使用。",
                    "The new \(action) result was blocked for changing \(reason); the previous candidate is still available."
                )
            }
            return L(
                "候选触发了保护（\(reason)），已拦截；原文没有改变。",
                "The candidate was blocked for changing \(reason); the original is unchanged."
            )
        case "input_too_large":
            return L("当前选中文字过长，请缩短选区后再试；原文没有改变。", "The selection is too long. Select less text and try again; the original is unchanged.")
        case "instruction_too_large":
            return L("修改要求过长，请说得更简短一些。", "The instruction is too long. Try a shorter request.")
        case "no_instruction":
            return L("没有听清修改要求，请再说一次。", "No instruction was recognized. Please try again.")
        case "instruction_transcription_failed":
            return L("本地指令转写失败，请再说一次。", "The local instruction transcription failed. Please try again.")
        case "microphone_permission":
            return L("没有麦克风权限；仍可使用下面的快捷方式。", "Microphone access is unavailable; the shortcuts still work.")
        case "microphone_unavailable":
            return L("麦克风暂时打不开；仍可使用下面的快捷方式。", "The microphone could not start; the shortcuts still work.")
        case "provider_rate_limited":
            return L("供应商当前限流，请稍后手动重试；原文没有改变。", "The provider is rate-limiting requests. Retry later; the original is unchanged.")
        case "provider_quota_exhausted":
            return L("当前供应商额度已经用完；请等待额度重置或更换供应商。原文没有改变。", "This provider's quota is exhausted. Wait for it to reset or choose another provider; the original is unchanged.")
        case "provider_balance_exhausted":
            return L("当前供应商账户余额不足；请检查账户或更换供应商。原文没有改变。", "This provider account has insufficient balance. Check the account or choose another provider; the original is unchanged.")
        case "provider_model_not_available":
            return L("当前账户不能使用所选模型；请更换模型或供应商。原文没有改变。", "This account cannot use the selected model. Choose another model or provider; the original is unchanged.")
        case "provider_high_traffic":
            return L("供应商当前繁忙，请稍后手动重试；原文没有改变。", "The provider is currently busy. Retry later; the original is unchanged.")
        case "provider_policy_limited":
            return L("供应商限制了当前账户的请求；请检查账户状态或更换供应商。原文没有改变。", "The provider has restricted requests from this account. Check its status or choose another provider; the original is unchanged.")
        case "provider_timeout":
            return EnhancementFailureMessage.message(code: code, stage: model.result?.providerFailureStage)
        case "provider_network_error":
            return L("无法连接文字处理供应商；请检查网络后重试。原文没有改变。", "The text provider could not be reached. Check the network and retry; the original is unchanged.")
        case "provider_unavailable", "provider_failed", "daemon":
            return L("暂时无法生成候选，请稍后手动重试；原文没有改变。", "A candidate could not be generated. Retry later; the original is unchanged.")
        case "network_not_authorized":
            return L("本次操作没有联网授权；原文没有改变。", "This action was not authorized to use the network; the original is unchanged.")
        default:
            return EnhancementFailureMessage.message(code: code, stage: model.result?.providerFailureStage)
        }
    }

    private var validationWarningMessage: String? {
        guard model.result?.readyForPreview == true else { return nil }
        let warnings = model.result?.validationWarnings ?? []
        guard !warnings.isEmpty else { return nil }
        let reason = validationReason(warnings)
        return L(
            "这版改动了\(reason)，请核对后再使用。",
            "This version changed \(reason). Review it before replacing the original."
        )
    }

    private func validationReason(_ codes: [String]) -> String {
        let issues = Set(codes)
        let zh: [(String, String)] = [
            ("numeric_changed", "数字"), ("url_changed", "链接"),
            ("email_changed", "邮箱"), ("file_path_changed", "文件路径"),
            ("identifier_changed", "技术标识"), ("quote_changed", "引文"),
            ("negation_changed", "否定关系"), ("stance_changed", "人物角色"),
            ("question_intent_changed", "疑问或确认意图"),
            ("commitment_changed", "承诺强度"), ("protected_term_changed", "受保护词"),
            ("language_changed", "主要语言"), ("output_too_long", "输出长度"),
        ]
        let en: [(String, String)] = [
            ("numeric_changed", "numbers"), ("url_changed", "links"),
            ("email_changed", "email addresses"), ("file_path_changed", "file paths"),
            ("identifier_changed", "technical identifiers"), ("quote_changed", "quoted text"),
            ("negation_changed", "negation"), ("stance_changed", "speaker roles"),
            ("question_intent_changed", "question or confirmation intent"),
            ("commitment_changed", "commitment strength"), ("protected_term_changed", "protected terms"),
            ("language_changed", "the main language"), ("output_too_long", "output length"),
        ]
        let labels = (Locale.current.language.languageCode?.identifier == "zh" ? zh : en)
            .compactMap { issues.contains($0.0) ? $0.1 : nil }
        if !labels.isEmpty { return labels.joined(separator: L("、", ", ")) }
        return L("受保护信息", "protected information")
    }
}

private struct TextCard: View {
    let label: String
    let text: String
    let emphasized: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(emphasized ? Theme.Palette.accent : Theme.Palette.textTertiary)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.Palette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.Palette.bgSurface))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .strokeBorder(emphasized ? Theme.Palette.accent.opacity(0.65) : Theme.Palette.borderSubtle)
        )
    }
}

private extension EnhancementOperation {
    var title: String {
        switch self {
        case .clean: return L("清理口语", "Clean up")
        case .smartDictation: return L("重新润色", "Refine again")
        case .concise: return L("精简", "Make concise")
        case .business: return L("商务表达", "Business tone")
        case .grammar: return L("语法纠错", "Fix grammar")
        case .translate: return L("中英互译", "Translate")
        case .tone: return L("商务表达", "Business tone")
        case .structure: return L("整理结构", "Structure")
        case .instruction: return L("语音指令", "Voice instruction")
        }
    }

    var symbol: String {
        switch self {
        case .clean: return "eraser"
        case .smartDictation: return "sparkles"
        case .concise: return "text.alignleft"
        case .business: return "briefcase"
        case .grammar: return "checkmark.circle"
        case .translate: return "character.book.closed"
        case .tone: return "briefcase"
        case .structure: return "list.bullet.rectangle"
        case .instruction: return "waveform"
        }
    }
}
