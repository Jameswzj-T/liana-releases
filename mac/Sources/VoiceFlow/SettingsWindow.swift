import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import SwiftUI
import Security


@MainActor
final class MainWindow {
    static let shared = MainWindow()
    private var window: NSWindow?

    func show(onHotkeyChange: @escaping (HotkeyConfig) -> Void,
              onEditHotkeyChange: @escaping (HotkeyConfig) -> Void,
              onFixHotkeyChange: @escaping (HotkeyConfig) -> Void) {
        if window == nil {
            let view = MainView(onHotkeyChange: onHotkeyChange, onEditHotkeyChange: onEditHotkeyChange, onFixHotkeyChange: onFixHotkeyChange)
            let win = NSWindow(contentViewController: NSHostingController(rootView: view))
            win.title = "Liana"
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            win.isMovableByWindowBackground = true
            win.setContentSize(NSSize(width: 900, height: 680))
            win.appearance = NSAppearance(named: .aqua)
            win.backgroundColor = NSColor(red: 0xF5 / 255.0, green: 0xF1 / 255.0, blue: 0xE8 / 255.0, alpha: 1)
            win.isReleasedWhenClosed = false
            window = win
        }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)   // App 已是 .regular(启动就设);先激活 App 再把窗口设 key 前置,输入法上下文才干净
        window?.makeKeyAndOrderFront(nil)
    }


    func hide() {
        window?.orderOut(nil)
    }
}

struct MainView: View {
    let onHotkeyChange: (HotkeyConfig) -> Void
    let onEditHotkeyChange: (HotkeyConfig) -> Void
    let onFixHotkeyChange: (HotkeyConfig) -> Void
    @State private var route = Route.home

    enum Route { case home, history, settings }

    var body: some View {
        ZStack {
            Theme.Palette.bgBase.ignoresSafeArea()
            switch route {
            case .home:
                HomeView(onOpenSettings: { route = .settings }, onOpenHistory: { route = .history })
            case .history:
                HistoryView(onBack: { route = .home })
            case .settings:
                SettingsView(onHotkeyChange: onHotkeyChange, onEditHotkeyChange: onEditHotkeyChange, onFixHotkeyChange: onFixHotkeyChange, onBack: { route = .home })
            }
        }
        .frame(minWidth: 900, minHeight: 680)
        .preferredColorScheme(.light)
    }
}

struct SettingsView: View {
    let onHotkeyChange: (HotkeyConfig) -> Void
    let onEditHotkeyChange: (HotkeyConfig) -> Void
    let onFixHotkeyChange: (HotkeyConfig) -> Void
    var onBack: () -> Void = {}
    @AppStorage("asrCloud") private var asrCloud = false              // 默认全本地;用户明确开启后才走云端 qwen3-asr-flash
    @AppStorage("contextAware") private var contextAware = true       // 上下文感知转写(默认开;只送专名词表,不送原文)







    @AppStorage("speakerVerify") private var speakerVerify = false
    @AppStorage("speakerThreshold") private var speakerThreshold = 0.5
    @ObservedObject private var enroll = SpeakerEnroll.shared
    @AppStorage("llmProvider") private var llmProvider = AppDefaults.defaultLLMProvider    // BYOK:润色供应商预设
    @AppStorage("llmBaseURL") private var llmBaseURL = ""
    @AppStorage("polishModel") private var polishModel = ""
    @AppStorage("textEnhancementEnabled") private var textEnhancementEnabled = false
    @AppStorage("smartDictationEnabled") private var smartDictationEnabled = false
    @AppStorage("lastSmartDictationStatus") private var lastSmartDictationStatus = ""
    @AppStorage("lastSmartDictationLatencyMS") private var lastSmartDictationLatencyMS = 0
    @State private var asrCloudKey = ""                               // 只暂存用户正在输入的新转写 key，不回显已存凭据
    @State private var hasSavedAsrCloudKey = false
    @State private var isReplacingAsrCloudKey = false
    @State private var asrKeyStatus = ""
    @State private var asrKeyError = false
    @State private var savingAsrKey = false
    @State private var apiKey = ""                                    // 仅保存用户正在输入的新 LLM key，不回显已存凭据
    @State private var hasSavedAPIKey = false
    @State private var isReplacingAPIKey = false
    @State private var keyStatus = ""
    @State private var keyError = false
    @State private var savingTextKey = false
    @State private var lastTextKeyCheck: CredentialCheckResult?
    @State private var lastAsrKeyCheck: CredentialCheckResult?
    @State private var textCredentialPresentation = CredentialPresentationState()
    @State private var asrCredentialPresentation = CredentialPresentationState()
    private var credentialOperationBusy: Bool { savingTextKey || savingAsrKey }
    @State private var micGranted = false                            // 权限状态(首次引导用)
    @State private var axGranted = false
    @State private var confirmingSpeakerClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(width: 30, height: 30).background(Circle().fill(Theme.Palette.bgElevated))
                }.buttonStyle(.plain).disabled(credentialOperationBusy)
                Text(L("设置", "Settings")).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    currentDictationPathSection

                    speechToTextSection

                    byokSection

                    shortcutsSection







                    speakerSection

                    permissionsSection
                }
                .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 24)
            }
        }
        .onAppear {
            refreshAsrCloudKeyState()
            refreshPolishKeyState(provider: llmProvider)
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionsSoon()   // 从系统设置授权完切回来 → 状态即时刷新
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in


            refreshPermissionsSoon()
        }
        .alert(L("清除声纹？", "Clear voiceprint?"), isPresented: $confirmingSpeakerClear) {
            Button(L("清除", "Clear"), role: .destructive) {
                speakerVerify = false
                enroll.clear()
                Task { await Transcriber.shared.setSpeaker(verify: false, threshold: speakerThreshold) }
            }
            Button(L("取消", "Cancel"), role: .cancel) { }
        } message: {
            Text(L("清除后，Liana 不再按你的声音过滤旁人声；之后可以重新登记。", "Liana will stop filtering by your voice. You can enroll again later."))
        }
    }



    private var currentDictationPathSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            section(L("当前听写链路", "Current dictation path"))
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    pathStage(
                        icon: effectiveCloudTranscription ? "cloud" : "laptopcomputer",
                        title: L("语音转文字", "Speech to text"),
                        service: asrCloud && asrCredentialPresentation.requiresRouteConfirmation
                            ? L("转写凭据状态待确认", "Transcription credentials unconfirmed")
                            : effectiveCloudTranscription
                            ? L("Qwen 云端 · 高准确", "Qwen cloud · High accuracy")
                            : L("Qwen3-ASR 0.6B · 本地", "Qwen3-ASR 0.6B · Local"),
                        dataNote: asrCloud && asrCredentialPresentation.requiresRouteConfirmation
                            ? L("可能沿用旧凭据，请看下方状态", "Existing credentials may still be in use; see below")
                            : effectiveCloudTranscription
                            ? L("上传音频", "Audio uploaded")
                            : L("音频留在本机", "Audio stays on this Mac"),
                        active: effectiveCloudTranscription
                    )

                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)

                    pathStage(
                        icon: "text.alignleft",
                        title: L("文字整理", "Text refinement"),
                        service: automaticRefinementService,
                        dataNote: smartDictationEnabled && textCredentialPresentation.requiresRouteConfirmation
                            ? L("可能沿用旧凭据，请看下方状态", "Existing credentials may still be in use; see below")
                            : effectiveAutomaticRefinement
                            ? L("只上传这一条文字", "Only this transcript is uploaded")
                            : L("普通听写文字不发送", "Dictated text is not sent"),
                        active: effectiveAutomaticRefinement
                    )
                }

                Divider().overlay(Theme.Palette.borderSubtle)

                Text(settingsPrivacySummary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .cardSurface(14)
        }
    }

    private func pathStage(
        icon: String,
        title: String,
        service: String,
        dataNote: String,
        active: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? Theme.Palette.accent : Theme.Palette.textSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.Palette.bgElevated))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(service)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(dataNote)
                    .font(.system(size: 11))
                    .foregroundStyle(active ? Theme.Palette.accent : Theme.Palette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var speechToTextSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            section(L("语音转文字", "Speech to text"))

            row(L("高准确云端转写", "High-accuracy cloud transcription"),
                L("使用 Qwen 云端识别短词、专名、中英混说和长句。开启后会上传音频并可能产生费用；失败自动回到本地 0.6B。",
                  "Uses Qwen cloud ASR for short terms, names, mixed-language speech, and long dictation. Audio is uploaded and may incur charges; failures fall back to local 0.6B.")) {
                Toggle("", isOn: $asrCloud).labelsHidden().toggleStyle(.switch).tint(Theme.Palette.accent)
                    .disabled(credentialOperationBusy)
                    .onChange(of: asrCloud) { _, _ in
                        Task { await Transcriber.shared.restart() }
                    }
            }

            asrCloudCredentialCard

            row(L("上下文提示（专名）", "Context hints (names)"),
                L("只读取光标附近的项目名和标识符作为拼写提示，不发送完整句子。使用云端转写时，这些提示会随音频请求发送。",
                  "Reads only nearby names and identifiers as spelling hints, not full sentences. With cloud transcription, these hints accompany the audio request.")) {
                Toggle("", isOn: $contextAware).labelsHidden().toggleStyle(.switch).tint(Theme.Palette.accent)
            }
        }
    }

    private var asrCloudCredentialCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Qwen 云端转写 Key", "Qwen cloud transcription key"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("DashScope · \(L("用于语音识别", "Speech recognition"))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer()
                credentialHeadline(asr: true)
            }

            if hasSavedAsrCloudKey && !isReplacingAsrCloudKey {
                savedCredentialRow(asr: true) {
                    asrCloudKey = ""
                    isReplacingAsrCloudKey = true
                    asrKeyStatus = ""
                    asrCredentialPresentation.dismissAction()
                }
            } else {
                HStack(spacing: 8) {
                    SecureField(L("粘贴新的转写 Key", "Paste a new transcription key"), text: $asrCloudKey)
                        .disabled(credentialOperationBusy)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.Palette.bgElevated))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.Palette.borderSubtle))
                        .onSubmit(saveAsrCloudKey)
                    if hasSavedAsrCloudKey {
                        Button(L("取消", "Cancel")) {
                            asrCloudKey = ""
                            isReplacingAsrCloudKey = false
                            asrKeyStatus = ""
                            asrCredentialPresentation.dismissAction()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .disabled(credentialOperationBusy)
                    }
                    saveCapsuleButton(action: saveAsrCloudKey).disabled(credentialOperationBusy)
                }
            }

            credentialDetails(asr: true)
            if credentialPresentation(asr: true).showRecovery { credentialRecoveryRow(asr: true) }
            if asrCredentialPresentation.canManuallyTestStoredKey && !credentialPresentation(asr: true).showRecovery { serviceCheckRow(asr: true) }
            if savingAsrKey { ProgressView().controlSize(.small) }
            Text(L("重新授权仅在本机读取并加载 Key，不做云端测试。保存并测试或测试服务会发送一次程序生成的1秒静音片段，可能产生少量费用；不使用麦克风、历史录音，也不打开云端转写。", "Authorize access only reads and loads the key locally, without a cloud test. Save and test or Test service sends one generated 1-second silent clip and may incur a small charge. It uses no microphone or recording history and does not enable cloud transcription."))
                .font(.system(size: 11)).foregroundStyle(Theme.Palette.textTertiary)
            Text(L("Key 只存本机钥匙串。只有开启高准确云端转写时才会上传录音；Vocabulary 和上下文专名仅作为候选拼写。",
                   "The key stays in macOS Keychain. Audio is uploaded only when high-accuracy cloud transcription is enabled; Vocabulary and nearby names are spelling hints only."))
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(cloudTranscriptionStatus)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(asrCloud && credentialPresentation(asr: true).tone == .warning ? Theme.Palette.warning : Theme.Palette.textSecondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .cardSurface(14)
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            section(L("快捷键", "Shortcuts"))
            row(L("听写热键", "Dictation Hotkey"), L("点一下开始，再点一下结束", "Tap once to start, again to finish")) {
                HotkeyRecorderView(onChange: onHotkeyChange)
            }
            row(L("文字增强热键", "Text Enhancement Hotkey"),
                L("选中文字后口述要求或选择快捷操作，预览确认后再替换", "Select text, speak an instruction or choose a shortcut, then approve the preview")) {
                HotkeyRecorderView(slot: .edit, onChange: onEditHotkeyChange)
            }
            row(L("改上一条热键", "Fix-Last Hotkey"),
                L("上一句听错时立即修改，并选择是否记住写法", "Correct the last dictation and choose whether to remember the spelling")) {
                HotkeyRecorderView(slot: .fix, onChange: onFixHotkeyChange)
            }
        }
    }

    private func section(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.Palette.textTertiary).tracking(1.5)
            .textCase(.uppercase).padding(.top, 4)
    }

    private var effectiveCloudTranscription: Bool {
        asrCloud && asrCredentialPresentation.readableStorage && !asrCredentialPresentation.requiresRouteConfirmation
    }

    private var effectiveAutomaticRefinement: Bool {
        smartDictationEnabled && textCredentialPresentation.readableStorage && !textCredentialPresentation.requiresRouteConfirmation
    }

    private var automaticRefinementService: String {
        guard smartDictationEnabled else {
            return L("不自动整理", "Automatic refinement off")
        }
        if textCredentialPresentation.requiresRouteConfirmation {
            return L("文字凭据状态待确认", "Text credentials unconfirmed")
        }
        guard textCredentialPresentation.readableStorage else {
            return L("等待可读取的文字模型 Key", "Readable text model key required")
        }
        let configuration = selectedProviderConfiguration
        return configuration.model.isEmpty
            ? selectedProviderName
            : "\(selectedProviderName) · \(configuration.model)"
    }

    private var cloudTranscriptionStatus: String {
        let copy = credentialPresentation(asr: true).summary
        return L(copy.zh, copy.en)
    }

    private var speakerThresholdLabel: String {
        if speakerThreshold < 0.43 { return L("偏宽松", "Looser") }
        if speakerThreshold > 0.57 { return L("偏严格", "Stricter") }
        return L("平衡", "Balanced")
    }


    private func row<T: View>(_ title: String?, _ desc: String?, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                if let title { Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.Palette.textPrimary) }
                if let desc { Text(desc).font(.system(size: 11.5)).foregroundStyle(Theme.Palette.textSecondary) }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .cardSurface(14)
    }

    private func savedCredentialRow(asr: Bool, onReplace: @escaping () -> Void) -> some View {
        let state = asr ? asrCredentialPresentation : textCredentialPresentation
        let uncertain = state.requiresRouteConfirmation
        return HStack(spacing: 10) {
            Text("••••••••••••")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.Palette.textSecondary)
            Label(uncertain ? L("Key 状态待确认", "Key state is unconfirmed") : L("已安全存入钥匙串", "Saved in Keychain"), systemImage: uncertain ? "questionmark.circle" : "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(uncertain ? Theme.Palette.textSecondary : Theme.Palette.accent)
            Spacer()
            Button(L("更换", "Replace"), action: onReplace)
                .disabled(credentialOperationBusy)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fontWeight(.medium)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Theme.Palette.bgElevated))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.Palette.bgElevated.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.Palette.borderSubtle))
    }

    private func saveCapsuleButton(action: @escaping () -> Void) -> some View {
        Button(L("保存并测试", "Save and test"), action: action)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.accentInk)
            .fontWeight(.semibold)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(Theme.Palette.accent))
    }


    private var speakerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            section(L("声纹 · 只听我", "Voiceprint · only me"))
            row(L("我的声音", "My voice"),
                !enroll.available ? L("声纹模型未安装", "Voiceprint model not installed")
                : (enroll.enrolled ? L("已登记 ✓ · 打开下面开关只识别你", "Enrolled ✓ · toggle below to filter")
                                   : L("登记一次,之后会尽量过滤旁边的人声", "Enroll once; then nearby speech is filtered as much as possible"))) {
                if enroll.recording {
                    Text(L("请读一句话… \(enroll.countdown)s", "Read a sentence… \(enroll.countdown)s"))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Palette.accent)
                } else {
                    HStack(spacing: 8) {
                        if enroll.available {
                            Button(enroll.enrolled ? L("重录", "Re-record") : L("登记我的声音", "Enroll")) { enroll.startEnroll() }
                                .buttonStyle(.plain).foregroundStyle(Theme.Palette.accentInk)
                                .padding(.horizontal, 12).padding(.vertical, 7).background(Capsule().fill(Theme.Palette.accent))
                        } else if enroll.enrolled {
                            Text(L("当前不可用", "Unavailable in this build"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        if enroll.enrolled {
                            Button(L("清除", "Clear")) { confirmingSpeakerClear = true }
                                .buttonStyle(.plain).foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                }
            }
            if enroll.enrolled && enroll.available {
                row(L("只识别我的声音", "Only my voice"), L("尽量过滤旁边人声；多人同时说话时无法完全隔离", "Best-effort filter; overlapping speakers cannot be fully separated")) {
                    Toggle("", isOn: $speakerVerify).labelsHidden().toggleStyle(.switch).tint(Theme.Palette.accent)
                        .onChange(of: speakerVerify) { _, v in
                            Task { await Transcriber.shared.setSpeaker(verify: v, threshold: speakerThreshold) }
                        }
                }
                if speakerVerify {
                    row(L("过滤强度", "Filter strength"), L("越严格越容易挡住旁人声，也更可能漏掉你自己。重叠说话时仍无法完全分离。", "Stricter filtering blocks more nearby speech, but can also drop your own voice. Overlapping speakers cannot be fully separated.")) {
                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(L("宽松", "Loose"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.Palette.textTertiary)
                                Slider(value: $speakerThreshold, in: 0.3...0.7)
                                    .frame(width: 112).tint(Theme.Palette.accent)
                                    .onChange(of: speakerThreshold) { _, v in
                                        Task { await Transcriber.shared.setSpeaker(verify: speakerVerify, threshold: v) }
                                    }
                                Text(L("严格", "Strict"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.Palette.textTertiary)
                            }
                            Text(L("当前：\(speakerThresholdLabel)", "Current: \(speakerThresholdLabel)"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        .frame(width: 190, alignment: .trailing)
                    }
                }
            } else if enroll.enrolled {
                row(L("只识别我的声音", "Only my voice"),
                    L("当前版本未安装声纹模型；已有登记记录保留，但过滤暂不生效。", "The voiceprint model is not installed in this build; the old enrollment is kept, but filtering is inactive.")) {
                    Text(L("不可用", "Unavailable"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
        }
        .onAppear { if speakerThreshold == 0 { speakerThreshold = 0.5 }; enroll.refresh() }
    }


    private var byokSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            section(L("文字整理", "Text refinement"))
            HStack(spacing: 6) {
                Circle().fill(cloudTextIsReady ? Theme.Palette.accent : Theme.Palette.textTertiary).frame(width: 7, height: 7)
                Text(cloudTextStatus)
                    .font(.system(size: 12)).foregroundStyle(Theme.Palette.textSecondary)
            }
            if smartDictationEnabled, let lastSmartDictationSummary {
                Label(lastSmartDictationSummary, systemImage: lastSmartDictationStatus == "fallback" ? "arrow.uturn.backward.circle" : "checkmark.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(lastSmartDictationStatus == "fallback" ? Theme.Palette.warning : Theme.Palette.accent)
            }
            row(L("自动整理听写", "Automatically refine dictation"),
                L("每次转写完成后，只发送这一条文字，清理口头禅、重复和明显语病，必要时分段，保留原意与细节。这个开关不发送音频；音频上传由上面的转写开关控制。失败时保留转写结果。", "Sends only the current transcript to clean fillers, repetition and clear language errors, adding paragraph breaks when needed while preserving meaning and details. This switch sends no audio; audio upload is controlled separately above. Failures keep the transcript.")) {
                Toggle("", isOn: $smartDictationEnabled).labelsHidden().toggleStyle(.switch).tint(Theme.Palette.accent)
                    .disabled(credentialOperationBusy)
                    .onChange(of: smartDictationEnabled) { _, _ in
                        lastSmartDictationStatus = ""
                        Task { await Transcriber.shared.restart() }
                    }
            }
            row(L("启用选中文字增强", "Enable selected-text enhancement"),
                L("选中文字后，可口述要求或使用翻译、精简、商务表达、整理结构等快捷方式；每次先预览，确认后才替换。", "After selecting text, speak an instruction or use Translate, Concise, Business, or Structure. Every result is previewed and replaces text only after approval.")) {
                Toggle("", isOn: $textEnhancementEnabled).labelsHidden().toggleStyle(.switch).tint(Theme.Palette.accent)
                    .disabled(credentialOperationBusy)
                    .onChange(of: textEnhancementEnabled) { _, _ in
                        Task { await Transcriber.shared.restart() }
                    }
            }
            row(L("供应商", "Provider"), L("自动整理和选区改写共用这一家文字模型；不会自动改投其他供应商。", "Automatic refinement and selected-text rewriting use this provider. Liana never switches providers automatically.")) {
                Picker("", selection: $llmProvider) {
                    ForEach(providerOptions, id: \.1) { option in
                        Text(option.0).tag(option.1)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(credentialOperationBusy)
                .onChange(of: llmProvider) { _, provider in
                    selectProvider(provider)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("\(selectedProviderName) 文字模型 Key", "\(selectedProviderName) text model key"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text(L("用于自动整理和选区改写", "Automatic refinement and selected-text rewriting"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    Spacer()
                    credentialHeadline(asr: false)
                }
                if hasSavedAPIKey && !isReplacingAPIKey {
                    savedCredentialRow(asr: false) {
                        apiKey = ""
                        isReplacingAPIKey = true
                        keyStatus = ""
                        textCredentialPresentation.dismissAction()
                    }
                } else {
                    HStack(spacing: 8) {
                        SecureField(L("粘贴新的 key", "Paste a new key"), text: $apiKey)
                            .disabled(credentialOperationBusy)
                            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.Palette.textPrimary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.Palette.bgElevated))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.Palette.borderSubtle))
                            .onSubmit(saveKey)
                        if hasSavedAPIKey {
                            Button(L("取消", "Cancel")) {
                                apiKey = ""
                                isReplacingAPIKey = false
                                keyStatus = ""
                                textCredentialPresentation.dismissAction()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .disabled(credentialOperationBusy)
                        }
                        saveCapsuleButton(action: saveKey).disabled(credentialOperationBusy)
                    }
                }
                credentialDetails(asr: false)
                if credentialPresentation(asr: false).showRecovery { credentialRecoveryRow(asr: false) }
                if textCredentialPresentation.canManuallyTestStoredKey && !credentialPresentation(asr: false).showRecovery { serviceCheckRow(asr: false) }
                if savingTextKey { ProgressView().controlSize(.small) }
                Text(L("重新授权仅在本机读取并加载 Key，不做云端测试。保存并测试或测试服务会向所选文字模型发送一次固定测试句，可能产生少量费用；不会发送你的听写或历史，也不会开启自动整理。", "Authorize access only reads and loads the key locally, without a cloud test. Save and test or Test service sends one fixed test sentence to the selected model and may incur a small charge. It sends no dictation or history and does not enable automatic refinement."))
                    .font(.system(size: 11)).foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .cardSurface(14)
            if llmProvider == "custom" {
                row(L("接口地址", "Base URL"), nil) {
                    TextField("https://…", text: $llmBaseURL).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        .disabled(credentialOperationBusy)
                        .onChange(of: llmBaseURL) { _, _ in invalidateCustomTextConfiguration() }
                        .frame(width: 240).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Palette.bgElevated))
                }
                row(L("模型", "Model"), nil) {
                    TextField("model-name", text: $polishModel).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        .disabled(credentialOperationBusy)
                        .onChange(of: polishModel) { _, _ in invalidateCustomTextConfiguration() }
                        .frame(width: 240).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Palette.bgElevated))
                }
            }
            if llmProvider == "gemini" {
                Text(L(
                    "隐私提示：Google 官方说明 Gemini 免费 API 层会使用提交内容改进其产品。敏感文字请改用付费层或其他供应商。",
                    "Privacy note: Google says content submitted through the free Gemini API tier may be used to improve its products. Use a paid tier or another provider for sensitive text."
                ))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.warning)
            }
            Text(L("Key 只存本机钥匙串。自动整理开启时，每次听写文字会发送给上方供应商，可能产生费用；选区改写只在你主动操作时发送选中文字和指令。这两个文字功能自身不上传音频，也不会自动重试或转发给另一家；音频上云由转写区的独立开关控制。", "The key stays in macOS Keychain. Automatic refinement sends each dictated text to this provider and may incur charges; selected-text rewriting sends text only when invoked. These text features do not upload audio, retry automatically, or forward to another provider; the separate transcription switch controls audio upload."))
                .font(.system(size: 11)).foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private var cloudTextIsReady: Bool {
        hasSavedAPIKey && lastTextKeyCheck?.verified == true && (smartDictationEnabled || textEnhancementEnabled)
    }

    private var providerOptions: [(String, String)] {
        [
            (L("通义", "Qwen"), "qwen"),
            (L("豆包", "Doubao"), "doubao"),
            ("MiMo", "mimo"),
            ("DeepSeek", "deepseek"),
            ("GLM 4.7", "glm"),
            ("GLM 5.3", "glm53"),
            ("Gemini", "gemini"),
            (L("自定义", "Custom"), "custom"),
        ]
    }

    private var selectedProviderConfiguration: LLMProviderConfiguration {
        LLMProviderPreset.configuration(
            for: llmProvider,
            customBaseURL: llmBaseURL,
            customModel: polishModel
        )
    }

    private var selectedProviderName: String {
        switch LLMProviderPreset(rawValue: llmProvider) ?? .custom {
        case .qwen: return L("通义", "Qwen")
        case .doubao: return L("豆包", "Doubao")
        case .mimo: return "MiMo"
        case .deepseek: return "DeepSeek"
        case .glm: return "GLM 4.7"
        case .glm53: return "GLM 5.3"
        case .gemini: return "Gemini"
        case .custom: return L("自定义", "Custom")
        }
    }

    private var cloudTextStatus: String {
        let model = selectedProviderConfiguration.model
        let providerAndModel = model.isEmpty ? selectedProviderName : "\(selectedProviderName) · \(model)"
        let copy = credentialPresentation(asr: false).summary
        return "\(providerAndModel) · \(L(copy.zh, copy.en))"
    }

    private var lastSmartDictationSummary: String? {
        switch lastSmartDictationStatus {
        case "applied":
            return L("上次自动整理已应用 · \(lastSmartDictationLatencyMS) ms", "Last automatic refinement applied · \(lastSmartDictationLatencyMS) ms")
        case "unchanged":
            return L("上次模型判断无需修改 · \(lastSmartDictationLatencyMS) ms", "The last result needed no changes · \(lastSmartDictationLatencyMS) ms")
        case "fallback":
            return L("上次整理未采用，已保留转写结果 · \(lastSmartDictationLatencyMS) ms", "Last refinement not applied; transcript kept · \(lastSmartDictationLatencyMS) ms")
        default:
            return nil
        }
    }

    private var settingsPrivacySummary: String {
        if (asrCloud && asrCredentialPresentation.requiresRouteConfirmation)
            || (smartDictationEnabled && textCredentialPresentation.requiresRouteConfirmation) {
            return L("后台凭据状态尚未确认，当前链路尚未核实。读取失败不代表已停止使用旧凭据。请查看下方处理提示；若要停止向某服务发送内容，请关闭对应的云端转写或自动整理开关。", "Backend credential state and the current path are unconfirmed. A failed read does not mean existing credentials stopped being used. Follow the guidance below, or turn off the corresponding cloud transcription or automatic refinement switch to stop sending to that service.")
        }
        if effectiveCloudTranscription && effectiveAutomaticRefinement {
            return L(
                "当前高标准链路：录音先发送给 Qwen 云端转写，转写文字再发送给你选择的文字模型自动整理；任一服务失败都会保留或回到本地结果。两次请求彼此独立，都可能产生费用。",
                "Current high-standard path: audio goes to Qwen cloud ASR, then the transcript goes to your selected text model. Either failure preserves or falls back to the local result. These are separate requests and both may incur charges."
            )
        }
        if effectiveCloudTranscription {
            return L(
                "高准确云端转写已开启：录音会发送给 Qwen；自动整理关闭时，转写文字不会再自动发送给文字模型。云端失败会回到本地 0.6B。",
                "High-accuracy cloud transcription is on: audio is sent to Qwen. With automatic refinement off, transcript text is not automatically sent to a text model. Cloud failures fall back to local 0.6B."
            )
        }
        if effectiveAutomaticRefinement {
            return L(
                "本地 Qwen3-ASR 0.6B 负责听写；自动整理会把每条转写文字发送给你选择的模型，失败则保留本地结果。云端转写仍是上方独立开关，常用写法与纠错始终在本地处理。",
                "Local Qwen3-ASR 0.6B transcribes speech. Automatic refinement sends each text result to your chosen model and keeps the local result on failure. Cloud transcription remains a separate switch; spelling preferences and corrections stay local."
            )
        }
        if asrCloud && !hasSavedAsrCloudKey {
            return L(
                "高准确云端转写已打开，但当前没有可读取的转写 Key，因此仍由本地 0.6B 处理。请查看下方 Key 状态。",
                "High-accuracy cloud transcription is enabled, but no readable key is available, so local 0.6B still handles the audio. See the key status below."
            )
        }
        if smartDictationEnabled && !hasSavedAPIKey {
            return L(
                "自动整理已打开，但当前没有可读取的文字 Key，因此普通听写保留转写结果。请查看下方 Key 状态。",
                "Automatic refinement is enabled, but no readable text key is available. Dictation keeps the transcript. See the key status below."
            )
        }
        return L(
            "默认全本地转写；云端转写需要单独打开。自动整理关闭时，普通听写不会发送给文字模型；选区改写只在你主动操作时联网。常用写法和听写纠错始终在本地处理。",
            "Transcription is local by default. Cloud transcription has its own switch. With automatic refinement off, normal dictation is not sent to the text model; selected-text rewriting goes online only when you invoke it. Spelling preferences and corrections stay local."
        )
    }

    private func selectProvider(_ provider: String) {
        lastSmartDictationStatus = ""
        lastTextKeyCheck = nil
        refreshPolishKeyState(provider: provider)
        if !keyError {
            keyStatus = hasSavedAPIKey
                ? L("已找到该供应商的 Key", "Key found for this provider")
                : L("请保存该供应商的 Key", "Save a key for this provider")
        }
        Task { await Transcriber.shared.restart() }
    }

    private func saveKey() {
        saveCredential(.text)
    }

    private func invalidateCustomTextConfiguration() {


        lastTextKeyCheck = nil; keyStatus = ""
        CredentialAccessUncertainty.shared.mark(CredentialAccessUncertainty.identity(asr: false, provider: llmProvider))
        textCredentialPresentation.configurationChanged(backendUnconfirmed: true)
    }

    private func saveCredential(_ kind: CredentialKind) {
        let asr = kind == .asr
        let clean = (asr ? asrCloudKey : apiKey).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            if asr { asrKeyStatus = L("请先粘贴 Key", "Paste a key first"); asrCredentialPresentation.requireInput() }
            else { keyStatus = L("请先粘贴 Key", "Paste a key first"); textCredentialPresentation.requireInput() }
            return
        }
        guard !credentialOperationBusy else { return }
        let provider = llmProvider
            if asr { savingAsrKey = true; asrKeyError = false; lastAsrKeyCheck = nil }
        else { savingTextKey = true; keyError = false; lastTextKeyCheck = nil }
        Task { @MainActor in
            defer { if asr { savingAsrKey = false } else { savingTextKey = false } }
            let outcome = await CredentialSetupFlow.run(save: {
                let result = await Task.detached(priority: .userInitiated) {
                    asr ? AppDefaults.saveAsrCloudKey(clean) : AppDefaults.savePolishKey(clean, provider: provider)
                }.value
                DeliveryDiagnostics.shared.credentialEvent(kind: kind, stage: "save", osStatus: result.writeStatus)
                if let verification = result.verificationStatus {
                    DeliveryDiagnostics.shared.credentialEvent(kind: kind, stage: "readback", osStatus: verification)
                }
                return result
            }, verify: {
                await Transcriber.shared.restartAndVerifyCredential(kind)
            }, phase: { phase in
                if asr || llmProvider == provider { credentialProgress(phase, asr: asr) }
            })
            guard asr || llmProvider == provider else { return }
            if !outcome.saved.verified {
                CredentialAccessUncertainty.shared.recordSaveFailure(
                    CredentialAccessUncertainty.identity(asr: asr, provider: provider), result: outcome.saved)
                if asr { asrKeyError = true; asrKeyStatus = credentialSaveFailure(outcome.saved) }
                else { keyError = true; keyStatus = credentialSaveFailure(outcome.saved) }
                if asr { asrCredentialPresentation.saveFailed(write: outcome.saved.writeStatus, readback: outcome.saved.verificationStatus) }
                else { textCredentialPresentation.saveFailed(write: outcome.saved.writeStatus, readback: outcome.saved.verificationStatus) }
                return
            }


            if asr { hasSavedAsrCloudKey = true; isReplacingAsrCloudKey = false; asrCloudKey = "" }
            else { hasSavedAPIKey = true; isReplacingAPIKey = false; apiKey = "" }
        }
    }

    private func credentialProgress(_ phase: CredentialSetupPhase, asr: Bool) {
        let message: String
        switch phase {
        case .saving:
            if asr { asrCredentialPresentation.beginSave() } else { textCredentialPresentation.beginSave() }
            message = L("正在保存并读回验证；如有系统授权窗口，请先处理…", "Saving and verifying storage; respond to any system permission prompt…")
        case .checking:
            CredentialAccessUncertainty.shared.readSucceeded(CredentialAccessUncertainty.identity(asr: asr, provider: llmProvider))
            if asr { asrCredentialPresentation.storageVerified() } else { textCredentialPresentation.storageVerified() }
            message = L("Key 已存储，正在加载后台并测试服务，请稍候…", "Key stored. Loading the backend and testing the service; please wait…")
        case .finished(let result):
            let identity = CredentialAccessUncertainty.identity(asr: asr, provider: llmProvider)
            if CredentialAccessOutcome(check: result).confirmsLocalLoad {
                CredentialAccessUncertainty.shared.confirm(identity)
            } else {
                CredentialAccessUncertainty.shared.mark(identity)
            }
            if asr { asrCredentialPresentation.serviceFinished(code: result.code.rawValue) }
            else { textCredentialPresentation.serviceFinished(code: result.code.rawValue) }
            message = result.code.message
            if asr { lastAsrKeyCheck = result } else { lastTextKeyCheck = result }
        }
        if asr { asrKeyStatus = message } else { keyStatus = message }
    }

    private func refreshPolishKeyState(provider: String) {
        AppDefaults.prepareLegacyPolishKeyOwner(provider: provider)
        let state = AppDefaults.polishKeyState(provider: provider)
        textCredentialPresentation = CredentialPresentationState()
        textCredentialPresentation.observeRead(hasValue: state.value != nil, status: state.status,
            backendUnconfirmed: CredentialAccessUncertainty.shared.contains(CredentialAccessUncertainty.identity(asr: false, provider: provider)))
        CredentialAccessUncertainty.shared.restoreSaveEvidence(
            CredentialAccessUncertainty.identity(asr: false, provider: provider), into: &textCredentialPresentation)
        hasSavedAPIKey = textCredentialPresentation.readableStorage
        keyError = state.status != errSecSuccess && state.status != errSecItemNotFound
        keyStatus = keyError ? credentialReadFailure(state.status) : ""
        apiKey = ""
        isReplacingAPIKey = false
    }

    private func refreshAsrCloudKeyState() {
        let state = AppDefaults.asrCloudKeyState()
        asrCredentialPresentation.observeRead(hasValue: state.value != nil, status: state.status,
            backendUnconfirmed: CredentialAccessUncertainty.shared.contains(CredentialAccessUncertainty.identity(asr: true, provider: llmProvider)))
        CredentialAccessUncertainty.shared.restoreSaveEvidence(
            CredentialAccessUncertainty.identity(asr: true, provider: llmProvider), into: &asrCredentialPresentation)
        hasSavedAsrCloudKey = asrCredentialPresentation.readableStorage
        asrKeyError = state.status != errSecSuccess && state.status != errSecItemNotFound
        asrKeyStatus = asrKeyError ? credentialReadFailure(state.status) : ""
        asrCloudKey = ""
        isReplacingAsrCloudKey = false
    }

    private func saveAsrCloudKey() {
        saveCredential(.asr)
    }

    private func credentialReadFailure(_ status: OSStatus) -> String {
        if status == errSecAuthFailed {
            return L("本机钥匙串认证失败；不是云端 API 的错误", "macOS Keychain authentication failed, not a cloud API error") + " (\(status))"
        }
        return L("Key 读取未获授权或失败，请重新授权", "Key could not be read; authorize access again") + " (\(status))"
    }

    private func credentialSaveFailure(_ result: CredentialSaveResult) -> String {
        (result.writeStatus == errSecSuccess
         ? L("已写入但未能验证，暂不应用；输入已保留", "Written but not verified; not applied. Your input is retained")
         : L("未保存；输入已保留，请检查钥匙串授权", "Not saved. Your input is retained; check Keychain access")) + " (\(result.status))"
    }

    private func credentialRecoveryRow(asr: Bool) -> some View {
        HStack(spacing: 12) {
            Button(L("重新授权（不联网测试）", "Authorize access (no cloud test)")) { accessCredential(asr: asr, action: .authorizeOnly) }
                .disabled(savingAsrKey || savingTextKey)
            Button(L("打开钥匙串访问", "Open Keychain Access")) {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") {
                    NSWorkspace.shared.open(url)
                }
            }
            Text(L("不会删除旧 Key；不要填写 Mac 密码到 Key 输入框。",
                   "Existing keys are kept. Never enter your Mac password in a Key field."))
                .foregroundStyle(Theme.Palette.textTertiary)
        }.font(.system(size: 11))
    }

    private func accessCredential(asr: Bool, action: CredentialAccessAction) {
        guard !credentialOperationBusy else { return }
        let provider = llmProvider
        let configuration = selectedProviderConfiguration
        let kind: CredentialKind = asr ? .asr : .text
        let identity = CredentialAccessUncertainty.identity(asr: asr, provider: provider)
        CredentialAccessUncertainty.shared.mark(identity)
        if asr { savingAsrKey = true } else { savingTextKey = true }
        if asr { lastAsrKeyCheck = nil } else { lastTextKeyCheck = nil }

        if asr { asrCredentialPresentation.beginAuthorization() } else { textCredentialPresentation.beginAuthorization() }
        Task { @MainActor in
            defer { if asr { savingAsrKey = false } else { savingTextKey = false } }
            let outcome = await CredentialAccessFlow.run(action: action, isCurrent: {
                asr || (llmProvider == provider && selectedProviderConfiguration == configuration)
            }, read: {
                await Task.detached(priority: .userInitiated) {
                    asr ? AppDefaults.asrCloudKeyState(reload: true, allowInteraction: true)
                        : AppDefaults.polishKeyState(provider: provider, reload: true, allowInteraction: true)
                }.value
            }, observed: { state in
                if state.value != nil { CredentialAccessUncertainty.shared.readSucceeded(identity) }
                if asr {
                    asrCredentialPresentation.authorizationFinished(hasValue: state.value != nil, status: state.status, willTestService: action == .testService)
                    hasSavedAsrCloudKey = state.value != nil
                    asrKeyError = state.value == nil
                    if asrKeyError { asrKeyStatus = credentialReadFailure(state.status) }
                } else {
                    textCredentialPresentation.authorizationFinished(hasValue: state.value != nil, status: state.status, willTestService: action == .testService)
                    hasSavedAPIKey = state.value != nil
                    keyError = state.value == nil
                    if keyError { keyStatus = credentialReadFailure(state.status) }
                }
                DeliveryDiagnostics.shared.credentialEvent(kind: kind, stage: "read", osStatus: state.status)
            }, reload: {
                await Transcriber.shared.restartAndLoadCredential(kind)
            }, verify: {
                await Transcriber.shared.restartAndVerifyCredential(kind)
            })
            guard !outcome.superseded else { return }
            if outcome.confirmsLocalLoad { CredentialAccessUncertainty.shared.confirm(identity) }
            if let load = outcome.load {
                if asr { asrCredentialPresentation.localLoadFinished(code: load.rawValue) }
                else { textCredentialPresentation.localLoadFinished(code: load.rawValue) }
            }
            if let check = outcome.check {
                credentialProgress(.finished(check), asr: asr)
            }
        }
    }

    private func serviceCheckRow(asr: Bool) -> some View {
        Button(L("测试服务（可能计费）", "Test service (may incur charges)")) { accessCredential(asr: asr, action: .testService) }
            .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.Palette.accent).disabled(credentialOperationBusy)
    }

    private func credentialPresentation(asr: Bool) -> CredentialPresentation {
        .make(state: asr ? asrCredentialPresentation : textCredentialPresentation,
              usage: asr ? .asr(enabled: asrCloud)
                : .text(automatic: smartDictationEnabled, selected: textEnhancementEnabled))
    }

    private func credentialHeadline(asr: Bool) -> some View {
        let viewState = credentialPresentation(asr: asr)
        return Text(L(viewState.headline.zh, viewState.headline.en))
            .font(.system(size: 12))
            .foregroundStyle(viewState.tone == .warning ? Theme.Palette.warning
                : viewState.tone == .success ? Theme.Palette.accent : Theme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func credentialDetails(asr: Bool) -> some View {
        if let details = credentialPresentation(asr: asr).details {
            DisclosureGroup(L("状态详情", "Status details")) {
                Text(L(details.zh, details.en))
                    .font(.system(size: 11)).foregroundStyle(Theme.Palette.textSecondary)
                    .textSelection(.enabled)
            }.font(.system(size: 11)).foregroundStyle(Theme.Palette.textSecondary)
        }
    }


    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            section(L("权限", "Permissions"))
            permRow(L("麦克风", "Microphone"), L("录音必需", "Required for recording"),
                    granted: micGranted, pane: "Privacy_Microphone")
            permRow(L("辅助功能", "Accessibility"), L("全局热键 + 自动粘贴必需", "Required for hotkey & auto-paste"),
                    granted: axGranted, pane: "Privacy_Accessibility")
        }
    }

    private func permRow(_ title: String, _ desc: String, granted: Bool, pane: String) -> some View {
        row(title, desc) {
            if granted {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Palette.accent)
                    Text(L("已授权", "Granted")).font(.system(size: 12)).foregroundStyle(Theme.Palette.textSecondary)
                }
            } else {
                Button(L("去授权", "Grant")) {
                    requestPermission(pane: pane)
                }
                .buttonStyle(.plain).foregroundStyle(.white).fontWeight(.semibold)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Theme.Palette.danger))
            }
        }
    }

    private func refreshPermissions() {
        micGranted = AudioRecorder.microphoneGranted
        axGranted = AXIsProcessTrusted()
    }

    private func refreshPermissionsSoon() {
        refreshPermissions()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            refreshPermissions()
        }
    }

    private func requestPermission(pane: String) {
        if pane == "Privacy_Microphone" {
            switch AudioRecorder.microphonePermission {
            case .notDetermined:


                AudioRecorder.requestPermission { granted in
                    DispatchQueue.main.async {
                        micGranted = granted
                        refreshPermissionsSoon()
                    }
                }
            case .authorized:
                refreshPermissionsSoon()
            case .denied, .restricted:

                openPrivacyPane(pane)
            @unknown default:
                openPrivacyPane(pane)
            }
            return
        }

        if pane == "Privacy_Accessibility" {




            _ = AXIsProcessTrustedWithOptions(
                ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            )
        }
        openPrivacyPane(pane)
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
        refreshPermissionsSoon()
    }
}


struct Segmented: View {
    let options: [(String, String)]
    @Binding var sel: String
    var onChange: ((String) -> Void)? = nil

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.1) { o in
                Text(o.0).font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(sel == o.1 ? Theme.Palette.accentInk : Theme.Palette.textSecondary)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(sel == o.1 ? AnyShapeStyle(Theme.Palette.accent) : AnyShapeStyle(Color.clear))
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { sel = o.1; onChange?(o.1) }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.Palette.bgElevated))
    }
}


@MainActor
final class SpeakerEnroll: ObservableObject {
    static let shared = SpeakerEnroll()
    @Published var enrolled = false
    @Published var available = false
    @Published var recording = false
    @Published var countdown = 0
    private var recorder: AudioRecorder?

    func refresh() {
        Task {
            let s = await Transcriber.shared.speakerStatus()
            enrolled = s.enrolled; available = s.available
        }
    }


    func startEnroll() {
        guard !recording, available else { return }
        let rec = AudioRecorder()
        do { try rec.start() } catch { return }
        recorder = rec; recording = true; countdown = 6
        Task {
            for i in stride(from: 6, through: 1, by: -1) {
                countdown = i
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let url = rec.stopAndWriteWAV()
            recorder = nil; recording = false
            if let url {
                enrolled = await Transcriber.shared.enroll(path: url.path)
                TemporaryAudioFiles.shared.release(url)
            }
        }
    }

    func clear() {
        Task { await Transcriber.shared.speakerClear(); enrolled = false }
    }
}


@MainActor
final class VocabStore: ObservableObject {
    static let shared = VocabStore()
    @Published var text: String = ""

    struct ImportResult {
        let added: Int
        let skipped: Int
    }

    private var url: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("vocab.txt")
    }

    init() { text = (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    var terms: [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    func add(_ t: String) {
        let x = t.trimmingCharacters(in: .whitespaces)
        guard !x.isEmpty, !terms.contains(where: { $0.lowercased() == x.lowercased() }) else { return }
        text = (terms + [x]).joined(separator: "\n") + "\n"
        save()
    }

    func remove(_ t: String) {
        let kept = terms.filter { $0 != t }
        text = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        save()
    }


    func importFile(_ source: URL) throws -> ImportResult {
        let data = try Data(contentsOf: source)
        guard let incoming = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let candidates = incoming.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        var seen = Set(terms.map { $0.lowercased() })
        var added: [String] = []
        var skipped = 0
        for candidate in candidates {
            let key = candidate.lowercased()
            if seen.insert(key).inserted {
                added.append(candidate)
            } else {
                skipped += 1
            }
        }
        if !added.isEmpty {
            text = (terms + added).joined(separator: "\n") + "\n"
            save()
        }
        return ImportResult(added: added.count, skipped: skipped)
    }


    func export(to destination: URL) throws {
        let output = terms.isEmpty ? "" : terms.joined(separator: "\n") + "\n"
        try output.write(to: destination, atomically: true, encoding: .utf8)
    }

    func save() { try? text.write(to: url, atomically: true, encoding: .utf8) }
    func reload() { text = (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}



@MainActor
final class CorrectionsStore: ObservableObject {
    static let shared = CorrectionsStore()
    @Published var text: String = ""

    enum AddResult: Equatable {
        case added
        case updated
        case unchanged
        case invalid
    }

    private var url: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("corrections.txt")
    }

    init() { reload() }

    private static func split(_ line: Substring) -> (String, String)? {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
        for sep in ["→", "->", "\t"] {
            if let r = s.range(of: sep) {
                let w = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let rt = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !w.isEmpty, !rt.isEmpty { return (w, rt) }
            }
        }
        return nil
    }


    var pairs: [(wrong: String, right: String)] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { Self.split($0) }
    }



    static func upserting(wrong: String, right: String, in original: String) -> (text: String, result: AddResult) {
        let wrong = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = right.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = ["\n", "\r", "\t", "→", "->"]
        guard !wrong.isEmpty, !right.isEmpty, wrong != right,
              !forbidden.contains(where: { wrong.contains($0) || right.contains($0) })
        else { return (original, .invalid) }

        var lines = original.components(separatedBy: .newlines)
        while lines.last == "" { lines.removeLast() }
        for index in lines.indices {
            guard let pair = Self.split(Substring(lines[index])), pair.0 == wrong else { continue }
            guard pair.1 != right else { return (original, .unchanged) }
            lines[index] = "\(wrong)→\(right)"
            return (lines.joined(separator: "\n") + "\n", .updated)
        }
        lines.append("\(wrong)→\(right)")
        return (lines.joined(separator: "\n") + "\n", .added)
    }

    @discardableResult
    func add(wrong: String, right: String) -> AddResult {
        let update = Self.upserting(wrong: wrong, right: right, in: text)
        guard update.result == .added || update.result == .updated else { return update.result }
        text = update.text
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return update.result
    }


    func remove(wrong: String) {
        let kept = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .filter { line in
                guard let (w, _) = Self.split(line) else { return true }  // 注释/空行/无法解析的行:保留
                return w != wrong
            }
            .map(String.init)
        text = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func reload() { text = (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}


struct HotkeyRecorderView: View {
    var slot: HotkeyRecorder.Slot = .dictation   // 录哪个热键(听写 / 选中即改)
    let onChange: (HotkeyConfig) -> Void
    @StateObject private var rec = HotkeyRecorder()

    var body: some View {
        Button {
            rec.slot = slot
            rec.onChange = onChange
            rec.start()
        } label: {
            Text(rec.recording ? L("按任意键…(Esc 取消)", "Press any key… (Esc to cancel)") : rec.display)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(rec.recording ? Theme.Palette.accent : Theme.Palette.textPrimary)
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.Palette.bgElevated))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.Palette.borderSubtle))
        }
        .buttonStyle(.plain)
        .onAppear { rec.slot = slot; rec.refreshDisplay() }   // 显示该 slot 当前的热键
        .onDisappear { rec.endRecording() }   // 录制中途切走 → 清监听,别吞按键
    }
}


@MainActor
final class HotkeyRecorder: ObservableObject {
    enum Slot { case dictation, edit, fix }
    var slot: Slot = .dictation
    @Published var display = HotkeyConfig.current.prettyDisplay
    @Published var recording = false
    var onChange: ((HotkeyConfig) -> Void)?

    private var currentConfig: HotkeyConfig {
        switch slot { case .edit: return .currentEdit; case .fix: return .currentFix; case .dictation: return .current }
    }


    func refreshDisplay() { if !recording { display = currentConfig.prettyDisplay } }

    private var monitor: Any?
    private var pendingKeyCode: Int?
    private var pendingFlag: NSEvent.ModifierFlags = []


    func endRecording() {
        if recording { stop() }
    }

    func start() {
        guard !recording else { return }
        recording = true
        display = L("按任意键…", "Press any key…")
        pendingKeyCode = nil
        pendingFlag = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            self?.capture(e)
            return nil
        }
    }

    private func capture(_ e: NSEvent) {
        if e.type == .keyDown {
            if e.keyCode == 53 { stop(); return }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            finish(HotkeyConfig(keyCode: Int(e.keyCode), modifierRaw: mods.rawValue,
                                isModifierOnly: false, display: keyDisplay(e, mods)))
        } else {
            let active = e.modifierFlags.intersection([.command, .option, .control, .shift, .function])
            if !active.isEmpty {
                pendingKeyCode = Int(e.keyCode)
                pendingFlag = singleFlag(e)
            } else if let kc = pendingKeyCode {
                finish(HotkeyConfig(keyCode: kc, modifierRaw: pendingFlag.rawValue,
                                    isModifierOnly: true,
                                    display: HotkeyConfig.modifierSymbol(keyCode: kc) ?? modifierName(pendingFlag)))
            }
        }
    }

    private func finish(_ cfg: HotkeyConfig) {
        switch slot { case .edit: cfg.saveEdit(); case .fix: cfg.saveFix(); case .dictation: cfg.save() }
        display = cfg.prettyDisplay
        onChange?(cfg)
        stop()
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if display == L("按任意键…", "Press any key…") { display = currentConfig.prettyDisplay }
    }

    private func singleFlag(_ e: NSEvent) -> NSEvent.ModifierFlags {
        let f = e.modifierFlags
        if f.contains(.function) { return .function }
        if f.contains(.control) { return .control }
        if f.contains(.option) { return .option }
        if f.contains(.shift) { return .shift }
        if f.contains(.command) { return .command }
        return []
    }

    private func modifierName(_ f: NSEvent.ModifierFlags) -> String {
        if f.contains(.function) { return "fn" }
        if f.contains(.control) { return "⌃" }
        if f.contains(.option) { return "⌥" }
        if f.contains(.shift) { return "⇧" }
        if f.contains(.command) { return "⌘" }
        return "?"
    }

    private func keyDisplay(_ e: NSEvent, _ mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s + keyName(e)
    }

    private func keyName(_ e: NSEvent) -> String {
        switch Int(e.keyCode) {
        case 49: return "Space"
        case 36: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        default: return (e.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}
