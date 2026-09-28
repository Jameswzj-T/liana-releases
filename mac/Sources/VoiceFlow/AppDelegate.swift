import AppKit
import Carbon.HIToolbox
import CoreGraphics


@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber.shared
    private var hotkey: HotkeyManager!
    private var editHotkey: HotkeyManager!          // 选中文字增强的独立热键(默认右Option)
    private var fixHotkey: HotkeyManager!           // 改上一条的独立热键(默认 ⌘⇧U)
    private var isRecording = false
    private var recordingStartGate = RecordingStartGate()
    private var isProcessing = false
    private var processingWait: DictationWait?
    private var dictationToken = UUID()
    private var isEditing = false                   // 选中文字增强面板是否打开
    private var isEditInstructionRecording = false // 面板正在准备/录制一条本地语音指令
    private var editRecorderStarted = false         // AudioRecorder 是否已真正启动，避免准备期误 stop
    private var editRequestToken = UUID()           // 面板关掉/重开后忽略旧 provider 响应
    private var recordStart: Date?
    private var dictationTargetBundleID: String?    // 开录瞬间的最前台 App(应用感知风格用:它就是等下粘贴的目标)
    private var escMonitor: Any?
    private var escLocalMonitor: Any?
    private var escEventTap: CFMachPort?
    private var escEventTapSource: CFRunLoopSource?
    private var audioCont: AsyncStream<[Int16]>.Continuation?  // 录音中 16k 帧的出口
    private var streamPump: Task<Void, Never>?                 // 有序把帧送进守护进程的泵

    private var signalSources: [DispatchSourceSignal] = []




    private func installShutdownHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)   // 屏蔽默认"立即终止",改由下面的 source 在主线程优雅处理
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.recorder.shutdown()
                Task { await Transcriber.shared.streamCancel() }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDefaults.register()      // 必须最先:@AppStorage 的默认值不写进 UserDefaults,读的人拿不到
        if AppDefaults.deliveryDiagnosticsEnabled() {
            DeliveryDiagnostics.shared.started()
            vlog("诊断候选: delivery_diagnostics=1; 只增加交付元数据，不代表重复问题已修复")
        }
        installShutdownHandlers()   // 先装:Ctrl+C 优雅关音频,别卡死系统音频
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Liana")
        icon?.isTemplate = true   // 模板图:跟随菜单栏自动着色(白),不突兀;状态用 contentTintColor 提示
        statusItem.button?.image = icon
        if let dock = AppIconView.dockImage(variant: .cream) { NSApp.applicationIconImage = dock }  // Dock 图标:程序化 Liana 图标(奶油底 + 光谱波形)
        setupMainMenu()   // 主菜单栏(尤其【编辑】菜单):让 Cmd+V/C/X/A 在输入框里生效——否则 .regular app 无菜单栏、粘贴失灵


        let menu = NSMenu()
        if Bundle.main.object(forInfoDictionaryKey: "LianaDeliveryDiagnostics") as? Bool == true {
            let label = NSMenuItem(title: L("诊断试用候选 · 非发布版", "Diagnostic trial · Not a release"), action: nil, keyEquivalent: "")
            label.isEnabled = false
            menu.addItem(label)
            menu.addItem(.separator())
        }
        menu.addItem(NSMenuItem(title: L("打开 Liana…", "Open Liana…"), action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("退出 Liana", "Quit Liana"), action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu


        hotkey = HotkeyManager(onTrigger: { [weak self] in self?.toggleRecording() },
            canTrigger: { [weak self] in
                guard let self else { return false }
                return !self.isProcessing && !self.isEditing
            })
        hotkey.apply(HotkeyConfig.current)

        editHotkey = HotkeyManager(config: .editDefault, onTrigger: { [weak self] in self?.toggleEditMode() },
            canTrigger: { [weak self] in
                guard let self else { return false }
                return !self.isProcessing && !self.isRecording && !self.recordingStartGate.isPending
                    && (!self.isEditing || self.isEditInstructionRecording || TextEnhancementPanel.shared.canStartVoice)
            })
        editHotkey.apply(HotkeyConfig.currentEdit)

        fixHotkey = HotkeyManager(onTrigger: { [weak self] in self?.showFixLast() })
        fixHotkey.apply(HotkeyConfig.currentFix)


        Task { await transcriber.warmUp() }





        RecordingHUD.shared.preload()


        let engine = UserDefaults.standard.string(forKey: "asrEngine") ?? AppDefaults.currentASREngine
        if engine != AppDefaults.currentASREngine {
            Task { await transcriber.setEngine(engine) }
        }


        if ProcessInfo.processInfo.environment["VF_AXPROBE"] != nil {
            AXProbe.start()
        }





        DispatchQueue.main.async { [weak self] in
            self?.openSettings()
        }
    }



    func applicationWillTerminate(_ notification: Notification) {
        DeliveryDiagnostics.shared.flush()
        if isEditing {
            cancelEditMode()
        } else if isRecording {
            cancelRecording()
        }
        removeEscMonitor()
        recorder.shutdown()
        Transcriber.shared.interrupt()
        TemporaryAudioFiles.shared.cleanup()
        RecordingHUD.shared.hide()
        MainWindow.shared.hide()
        statusItem?.isVisible = false
    }



    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: L("退出 Liana", "Quit Liana"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("编辑", "Edit"))
        editMenu.addItem(NSMenuItem(title: L("剪切", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: L("拷贝", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: L("粘贴", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: L("全选", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }


    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openSettings() }
        return true
    }

    @objc private func openSettings() {
        MainWindow.shared.show(
            onHotkeyChange: { [weak self] hk in self?.hotkey.apply(hk) },
            onEditHotkeyChange: { [weak self] hk in self?.editHotkey.apply(hk) },
            onFixHotkeyChange: { [weak self] hk in self?.fixHotkey.apply(hk) }
        )
    }


    private func showFixLast() {
        FixLastPanel.shared.show()
    }

    @objc private func toggleRecording() {
        guard !isProcessing else { return }
        if isEditing { return }        // 改写进行中,忽略听写热键(两模式互斥)
        if recordingStartGate.isPending {
            recordingStartGate.cancel()
            hotkey.invalidatePendingTap()
            return
        }
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isProcessing, let startToken = recordingStartGate.begin() else { return }

        dictationTargetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier









        let contextOn = (UserDefaults.standard.object(forKey: "contextAware") as? Bool) ?? true  // 默认开
        Task { @MainActor in
            guard recordingStartGate.pending == startToken else { return }
            let allowed = await AudioRecorder.requestPermission()
            guard recordingStartGate.finish(startToken), !isProcessing, !isEditing else { return }
            guard allowed else {
                vlog("麦克风权限被拒")
                return
            }
            recorder.onSpectrum = { rms, bands in


                DispatchQueue.main.async { MainActor.assumeIsolated { RecordingHUD.shared.push(rms, bands) } }
            }

            let (frames, cont) = AsyncStream<[Int16]>.makeStream()
            audioCont = cont
            recorder.onChunk16k = { chunk in cont.yield(chunk) }




            recorder.onFirstBuffer = { NSSound(named: "Tink")?.play() }






            isRecording = true
            recordStart = Date()
            do {
                try recorder.start()
                vlog("开始录音")
            } catch {
                vlog("录音启动失败 \(error)")
                isRecording = false
                statusItem.button?.contentTintColor = nil
                recorder.onChunk16k = nil                   // 清音频回调
                audioCont?.finish(); audioCont = nil        // 结束流,别留悬空


                Toast.show("🎤 麦克风打不开——多半是别的应用(浏览器语音/会议)正占着,关掉它再试")
                return                                       // HUD / Esc 监听都还没装,不用回滚
            }




            statusItem.button?.contentTintColor = .systemRed  // 录音中:红
            RecordingHUD.shared.show(
                onCancel: { [weak self] in self?.handleEscape() },
                onConfirm: { [weak self] in self?.stopRecording() }
            )
            installEscMonitor()  // 录音中按 Esc 取消




            let context = contextOn ? (ScreenContext.aroundCursor() ?? "") : ""
            if !context.isEmpty { vlog("上下文感知:读到光标周围 \(context.count) 字") }
            streamPump = Task.detached {
                await Transcriber.shared.streamStart(context: context)
                for await chunk in frames {
                    await Transcriber.shared.streamAudio(chunk)
                }
            }
        }
    }






    private func installEscMonitor() {
        removeEscMonitor()

        let owner = Unmanaged.passUnretained(self).toOpaque()
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: EscapeCancellationEvent.keyDownMask,
            callback: Self.escapeEventTapCallback,
            userInfo: owner
        ) {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            escEventTap = tap
            escEventTapSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            vlog("Esc session event tap 创建失败，保留 NSEvent 回退")
        }


        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 {
                MainActor.assumeIsolated { self?.handleEscape() }
            }
        }


        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53 else { return e }
            MainActor.assumeIsolated { self?.handleEscape() }
            return nil
        }
    }

    private static let escapeEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated { owner.reenableEscEventTap() }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if EscapeCancellationEvent.shouldCancel(type: type, keyCode: keyCode) {
            MainActor.assumeIsolated { owner.handleEscape() }
        }
        return Unmanaged.passUnretained(event)
    }

    private func reenableEscEventTap() {
        guard let tap = escEventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleEscape() {
        recordingStartGate.cancel()
        hotkey.invalidatePendingTap()
        editHotkey.invalidatePendingTap()
        if isProcessing {
            dictationToken = UUID()
            if let processingWait { processingWait.cancel(interrupt: { transcriber.interrupt() }) }
            else { transcriber.interrupt() }
            processingWait = nil
            isProcessing = false
            removeEscMonitor()
            RecordingHUD.shared.hide()
            statusItem.button?.contentTintColor = nil
            return
        }
        if isEditing { cancelEditMode() } else if isRecording { cancelRecording() }
    }

    private func removeEscMonitor() {
        if let source = escEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            escEventTapSource = nil
        }
        if let tap = escEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            escEventTap = nil
        }
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        if let m = escLocalMonitor { NSEvent.removeMonitor(m); escLocalMonitor = nil }
    }


    private func cancelRecording() {
        recordingStartGate.cancel()
        hotkey.invalidatePendingTap()
        editHotkey.invalidatePendingTap()
        guard isRecording else { return }
        isRecording = false
        NSSound(named: "Funk")?.play()  // 取消音效:跟确认(Pop)区分,一听就知道这条被丢弃了
        removeEscMonitor()
        recorder.onChunk16k = nil
        audioCont?.finish()
        audioCont = nil
        streamPump?.cancel()
        streamPump = nil
        transcriber.interrupt()
        if let url = recorder.stopAndWriteWAV() { TemporaryAudioFiles.shared.release(url) }
        Task { await transcriber.streamCancel() }  // 让守护进程丢弃这条流
        RecordingHUD.shared.hide()
        statusItem.button?.contentTintColor = nil  // 恢复默认(白)
        vlog("已取消")
    }


    private func stopRecording() {
        recordingStartGate.cancel()
        hotkey.invalidatePendingTap()
        editHotkey.invalidatePendingTap()
        guard isRecording else { return }
        isRecording = false
        isProcessing = true
        let token = UUID()
        dictationToken = token
        NSSound(named: "Pop")?.play()
        RecordingHUD.shared.startProcessing()
        statusItem.button?.contentTintColor = .systemOrange
        recorder.onChunk16k = nil
        audioCont?.finish()
        audioCont = nil
        let pump = streamPump
        streamPump = nil
        guard let url = recorder.stopAndWriteWAV() else {
            pump?.cancel()
            isProcessing = false
            removeEscMonitor()
            RecordingHUD.shared.hide()
            statusItem.button?.contentTintColor = nil
            return
        }
        let duration = recordStart.map { Date().timeIntervalSince($0) } ?? 0
        let target = Paster.captureTarget()
        let style = Self.effectiveStyle(for: dictationTargetBundleID)
        let smart = UserDefaults.standard.bool(forKey: "smartDictationEnabled")
        let wait = DictationWait(runID: UUID())
        processingWait = wait
        let progress: @Sendable (DictationProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.dictationToken == token, self.isProcessing,
                      !wait.choseOriginal, progress.elapsed >= 4 else { return }
                RecordingHUD.shared.showPolishWait(onUseTranscript: { [weak self] in
                    guard let self, self.dictationToken == token, self.isProcessing else { return }
                    if wait.requestOriginal(interrupt: { self.transcriber.interrupt() }) {
                        RecordingHUD.shared.usingTranscript()
                    }
                }, onCancel: { [weak self] in self?.handleEscape() })
            }
        }
        Task { @MainActor in
            defer {
                TemporaryAudioFiles.shared.release(url)
                if dictationToken == token {
                    processingWait = nil
                    isProcessing = false
                    removeEscMonitor()
                    RecordingHUD.shared.finish()
                    statusItem.button?.contentTintColor = nil
                }
            }
            await pump?.value
            guard dictationToken == token else { return }
            let runID = wait.runID.uuidString.lowercased()

            var text = await transcriber.streamStop(style: style, smartEnhance: smart, runID: runID,
                wait: wait, onProgress: progress) { _ in }
            guard dictationToken == token else { return }
            if text.isEmpty {
                text = await transcriber.transcribe(path: url.path, style: style,
                    smartEnhance: smart, runID: runID, fallbackReason: "stream_empty",
                    wait: wait, onProgress: progress)
            }
            guard dictationToken == token else { return }
            if text.isEmpty {
                Toast.show(L("没有得到转写结果，请重试。", "No transcript returned. Please try again."))
                return
            }
            let backendRaw = await transcriber.lastRaw
            guard dictationToken == token else { return }
            guard let chosen = wait.finish(text: text, raw: backendRaw) else { return }
            text = chosen.text
            if wait.choseOriginal || wait.connectionFailed {
                let defaults = UserDefaults.standard
                defaults.set("fallback", forKey: "lastSmartDictationStatus")
                defaults.set(0, forKey: "lastSmartDictationLatencyMS")
                defaults.set(Date().timeIntervalSince1970, forKey: "lastSmartDictationAt")
                vlog("整理等待结束: run=\(runID) reason=\(wait.choseOriginal ? "user_used_transcript" : "backend_connection_lost")")
                if !wait.choseOriginal {
                    Toast.show(L("整理连接中断，已保留完整转写。", "Refinement disconnected. Your full transcript is preserved."), duration: 5)
                }
            }
            let recordID = DictationStore.shared.add(text: text, durationSec: duration, raw: chosen.raw, audioURL: url)
            let attempt = TextDeliveryAttempt()
            if let runUUID = UUID(uuidString: runID) {
                DeliveryDiagnostics.shared.associate(run: runUUID, history: recordID, delivery: attempt.id)
            }
            vlog("落字关联: run=\(runID) history=\(recordID?.uuidString.lowercased() ?? "-") delivery=\(attempt.id.uuidString.lowercased())")
            let receipt = Paster.deliver(text, to: target, attempt: attempt, trace: {
                vlog("落字: " + $0)
                DeliveryDiagnostics.shared.recordTrace($0)
            },
                traceParts: AppDefaults.deliveryDiagnosticsEnabled())
            if receipt.status != .submittedUnverified {
                Toast.show(L("输入已停止；可能已有部分文字，完整结果在历史记录中，请检查后使用。",
                             "Text insertion stopped and may be partial. The complete result is in History; review it before using it."), duration: 6)
            }
        }
    }



    @objc private func toggleEditMode() {
        guard !isProcessing else { return }
        if isRecording || recordingStartGate.isPending { return }
        if isEditing {
            if isEditInstructionRecording {
                stopEditInstructionRecording()
            } else if TextEnhancementPanel.shared.canStartVoice {
                startEditInstructionRecording()
            }
        } else {
            startEditMode()
        }
    }


    private func startEditMode() {


        waitModifiersReleased { [weak self] in self?.captureSelectionAndShowPreview() }
    }


    private func waitModifiersReleased(attempt: Int = 0, _ then: @escaping () -> Void) {
        let held = NSEvent.modifierFlags.intersection([.command, .shift, .option, .control])
        if held.isEmpty || attempt >= 33 {
            then()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                MainActor.assumeIsolated { self?.waitModifiersReleased(attempt: attempt + 1, then) }
            }
        }
    }

    private func captureSelectionAndShowPreview() {
        guard !isEditing, !isRecording, !isProcessing, !recordingStartGate.isPending else { return }

        let selectionTarget = Paster.captureTarget()
        guard let sel = Paster.copySelection(stillCurrent: { Paster.targetMatches(selectionTarget) }),
              !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound(named: "Funk")?.play()
            Toast.show(L("先选中要改的文字,再按改写热键", "Select the text to edit first, then press the edit hotkey"))
            return
        }
        isEditing = true
        statusItem.button?.contentTintColor = .systemBlue
        installEscMonitor()
        TextEnhancementPanel.shared.show(
            selection: sel,
            hotkeyDisplay: HotkeyConfig.currentEdit.prettyDisplay,
            onVoiceAction: { [weak self] in self?.handleEditVoiceAction() },
            onQuickAction: { [weak self] operation in self?.runQuickEnhancement(operation) },
            onDismiss: { [weak self] in self?.finishEditMode() }
        )
        startEditInstructionRecording(initial: true)
    }

    private func handleEditVoiceAction() {
        guard isEditing else { return }
        if isEditInstructionRecording {
            stopEditInstructionRecording()
        } else if TextEnhancementPanel.shared.canStartVoice {
            startEditInstructionRecording()
        }
    }


    private func startEditInstructionRecording(initial: Bool = false) {
        guard isEditing, !isRecording, !isEditInstructionRecording else { return }
        guard initial || TextEnhancementPanel.shared.canStartVoice else { return }

        let instructionToken = UUID()
        editRequestToken = instructionToken
        isEditInstructionRecording = true
        editRecorderStarted = false
        TextEnhancementPanel.shared.beginVoice()
        statusItem.button?.contentTintColor = .systemRed

        Task { @MainActor in
            guard isEditing, isEditInstructionRecording, editRequestToken == instructionToken else { return }
            let allowed = await AudioRecorder.requestPermission()
            guard isEditing, isEditInstructionRecording, editRequestToken == instructionToken else { return }
            guard allowed else {
                isEditInstructionRecording = false
                statusItem.button?.contentTintColor = .systemBlue
                TextEnhancementPanel.shared.fail("microphone_permission")
                return
            }

            recorder.onChunk16k = nil
            recorder.onSpectrum = { [weak self] rms, bands in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self?.isEditing == true,
                              self?.isEditInstructionRecording == true,
                              self?.editRequestToken == instructionToken else { return }
                        TextEnhancementPanel.shared.push(rms, bands)
                    }
                }
            }
            recorder.onFirstBuffer = { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self?.isEditing == true,
                              self?.isEditInstructionRecording == true,
                              self?.editRequestToken == instructionToken else { return }
                        TextEnhancementPanel.shared.markRecording()
                        NSSound(named: "Tink")?.play()
                    }
                }
            }

            do {
                try recorder.start()
                editRecorderStarted = true
                vlog("开始录制文字增强指令")
            } catch {
                vlog("文字增强指令录音启动失败 \(error)")
                isEditInstructionRecording = false
                editRecorderStarted = false
                recorder.onSpectrum = nil
                recorder.onFirstBuffer = nil
                statusItem.button?.contentTintColor = .systemBlue
                TextEnhancementPanel.shared.fail("microphone_unavailable")
            }
        }
    }

    private func stopEditInstructionRecording() {
        editHotkey.invalidatePendingTap()
        guard isEditing, isEditInstructionRecording else { return }
        editRequestToken = UUID()
        isEditInstructionRecording = false
        recorder.onSpectrum = nil
        recorder.onFirstBuffer = nil

        guard editRecorderStarted else {
            statusItem.button?.contentTintColor = .systemBlue
            TextEnhancementPanel.shared.fail("no_instruction")
            return
        }
        editRecorderStarted = false
        NSSound(named: "Pop")?.play()
        guard let url = recorder.stopAndWriteWAV() else {
            statusItem.button?.contentTintColor = .systemBlue
            TextEnhancementPanel.shared.fail("no_instruction")
            return
        }

        let source = TextEnhancementPanel.shared.requestSource
        let token = UUID()
        editRequestToken = token
        TextEnhancementPanel.shared.beginProcessing(.instruction)
        statusItem.button?.contentTintColor = .systemOrange
        Task { @MainActor in
            let result = await transcriber.enhanceInstructionPreview(
                selection: source,
                wavPath: url.path
            )
            TemporaryAudioFiles.shared.release(url)
            guard isEditing, editRequestToken == token else { return }
            vlog(
                "文字增强语音指令完成 ready=\(result.readyForPreview)"
                    + " changed=\(result.candidate != source)"
                    + " error=\(result.errorCode ?? "none")"
            )
            TextEnhancementPanel.shared.finish(result)
            statusItem.button?.contentTintColor = .systemBlue
        }
    }


    private func runQuickEnhancement(_ operation: EnhancementOperation) {
        guard isEditing, operation != .instruction else { return }
        discardEditInstructionRecording()
        let source = TextEnhancementPanel.shared.requestSource
        vlog("文字增强快捷动作开始 operation=\(operation.rawValue) chars=\(source.count)")
        let token = UUID()
        editRequestToken = token
        TextEnhancementPanel.shared.beginProcessing(operation)
        statusItem.button?.contentTintColor = .systemOrange
        Task { @MainActor in
            let result = await transcriber.enhancePreview(
                selection: source,
                operation: operation
            )
            guard isEditing, editRequestToken == token else { return }
            vlog(
                "文字增强快捷动作完成 operation=\(operation.rawValue)"
                    + " ready=\(result.readyForPreview) changed=\(result.candidate != source)"
                    + " error=\(result.errorCode ?? "none")"
            )
            TextEnhancementPanel.shared.finish(result)
            statusItem.button?.contentTintColor = .systemBlue
        }
    }

    private func discardEditInstructionRecording() {
        editHotkey.invalidatePendingTap()
        editRequestToken = UUID()
        let wasActive = isEditInstructionRecording || editRecorderStarted
        isEditInstructionRecording = false
        recorder.onSpectrum = nil
        recorder.onFirstBuffer = nil
        recorder.onChunk16k = nil
        if editRecorderStarted {
            editRecorderStarted = false
            if let url = recorder.stopAndWriteWAV() { TemporaryAudioFiles.shared.release(url) }
        }
        if wasActive { vlog("已丢弃文字增强指令录音") }
    }


    private func cancelEditMode() {
        editHotkey.invalidatePendingTap()
        guard isEditing else { return }
        NSSound(named: "Funk")?.play()
        TextEnhancementPanel.shared.cancel()

        if isEditing { finishEditMode() }
    }

    private func finishEditMode() {
        hotkey.invalidatePendingTap()
        editHotkey.invalidatePendingTap()
        guard isEditing else { return }
        discardEditInstructionRecording()
        editRequestToken = UUID()
        isEditing = false
        removeEscMonitor()
        statusItem.button?.contentTintColor = nil
    }


    static func effectiveStyle(for bundleID: String?) -> String {
        let manual = UserDefaults.standard.string(forKey: "polishStyle") ?? "clean"
        let appAware = (UserDefaults.standard.object(forKey: "appAwareStyle") as? Bool) ?? true  // 默认开
        guard appAware, let picked = AppStyleMap.style(for: bundleID) else { return manual }
        vlog("应用感知:\(bundleID ?? "?") → \(picked) 风格")
        return picked
    }

    @objc private func quit() {


        MainWindow.shared.hide()
        statusItem?.isVisible = false
        NSApplication.shared.terminate(nil)
    }
}
