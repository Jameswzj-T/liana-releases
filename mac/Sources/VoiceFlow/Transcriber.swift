import Foundation



actor Transcriber {
    static let shared = Transcriber()

    private var process = Process()
    private var stdinPipe = Pipe()
    private var stdoutPipe = Pipe()
    private let io = DaemonPipeIO()
    private let responseTimeout: Double
    private var responseDeadline = DaemonPipeIO.deadline(after: 300)
    nonisolated func interrupt() { io.cancel() }
    private var started = false
    private var credentialGeneration = ""
    private var credentialReadiness: [String: Any]?
    private(set) var lastRaw = ""     // 上一条听写的【原始转写】(未润色);编辑即学习按它记映射,匹配得上 raw 阶段的纠错

    init() { responseTimeout = 300 }


    init(connectedProcess: Process, input: Pipe, output: Pipe, responseTimeout: Double = 300) {
        self.process = connectedProcess
        self.stdinPipe = input
        self.stdoutPipe = output
        self.responseTimeout = responseTimeout
        self.started = true
    }






    private static func resolveProjectDir() -> URL {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment["LIANA_BRAIN_DIR"]
            ?? ProcessInfo.processInfo.environment["VOICEFLOW_DIR"]
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("brain"),
           fm.fileExists(atPath: bundled.appendingPathComponent("daemon.py").path) {
            return bundled
        }
        if let exe = Bundle.main.executableURL {           // 往上找含 brain/daemon.py 的祖先(合仓后 = liana/brain)
            var dir = exe.deletingLastPathComponent()
            for _ in 0..<6 {
                let brain = dir.appendingPathComponent("brain")
                if fm.fileExists(atPath: brain.appendingPathComponent("daemon.py").path) { return brain }
                dir = dir.deletingLastPathComponent()
            }
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Developer/projects/liana/brain")
    }




    private static func resolvePythonExecutable(in dir: URL) -> URL {
        let bundled = dir.appendingPathComponent(".venv/bin/python")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }

        let pointer = dir.appendingPathComponent("python-runtime-path.txt")
        if let raw = try? String(contentsOf: pointer, encoding: .utf8) {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return bundled
    }





    private static func daemonEnvironment() -> [String: String] {
        let d = UserDefaults.standard
        let provider = d.string(forKey: "llmProvider") ?? AppDefaults.defaultLLMProvider
        let polishState = AppDefaults.polishKeyState(provider: provider, defaults: d)
        let asrState = AppDefaults.asrCloudKeyState(defaults: d)
        DeliveryDiagnostics.shared.credentialEvent(kind: .text, stage: "read", osStatus: polishState.status)
        DeliveryDiagnostics.shared.credentialEvent(kind: .asr, stage: "read", osStatus: asrState.status)
        let polishKey = polishState.value
        let asrCloudKey = asrState.value
        var env = AppDefaults.credentialEnvironment(
            base: ProcessInfo.processInfo.environment,
            polishKey: polishKey,
            asrCloudKey: asrCloudKey,
            textEnhancementEnabled: d.bool(forKey: "textEnhancementEnabled"),
            smartDictationEnabled: d.bool(forKey: "smartDictationEnabled"),
            cloudTranscriptionEnabled: d.bool(forKey: "asrCloud")
        )
        let providerConfiguration = LLMProviderPreset.configuration(
            for: provider,
            customBaseURL: d.string(forKey: "llmBaseURL") ?? "",
            customModel: d.string(forKey: "polishModel") ?? ""
        )
        if !providerConfiguration.baseURL.isEmpty {
            env["LLM_BASE_URL"] = providerConfiguration.baseURL
        }
        if !providerConfiguration.model.isEmpty {
            env["POLISH_MODEL"] = providerConfiguration.model
        }
        if let engine = d.string(forKey: "asrEngine"), !engine.isEmpty { env["ASR_ENGINE"] = engine }  // daemon 启动即用已注册的本地引擎(新安装默认 qwen3_06;老用户显式设置不被覆盖)
        if d.bool(forKey: "polishShortToo") { env["POLISH_MIN_CHARS"] = "0" }                          // 短句也润色:关掉"短句直出"闸(默认关=短句瞬间出字)
        if d.bool(forKey: "asrCloud") { env["ASR_CLOUD"] = "1" }                                       // 高准确路线：有效短词到长句都走 qwen3-asr-flash；失败回落本地（默认关，独立 ASR_CLOUD_KEY）

        let cloudEnabled = env["ASR_CLOUD"] == "1"
        let cloudKeyAvailable = !(env[AppDefaults.asrCloudKeyAccount] ?? "").isEmpty
        vlog("云端转写配置: enabled=\(cloudEnabled) key_available=\(cloudKeyAvailable)")
        if d.bool(forKey: "speakerVerify") { env["SPEAKER_VERIFY"] = "1" }                            // 声纹「只听我」:启动即带上(默认关)
        let thr = d.double(forKey: "speakerThreshold")
        if thr > 0 { env["SPEAKER_THRESHOLD"] = String(thr) }


        env["PYTHONDONTWRITEBYTECODE"] = "1"
        return env
    }

    func warmUp() {
        start()
    }


    nonisolated func restart() async {
        io.cancel()
        await restartAfterInterrupt()
    }

    private func restartAfterInterrupt() {
        if process.isRunning { process.terminate() }
        started = false
        start()
    }


    nonisolated func restartAndLoadCredential(_ kind: CredentialKind) async -> CredentialLoadResult {
        io.cancel()
        return await restartAndLoad(kind)
    }

    private func restartAndLoad(_ kind: CredentialKind) -> CredentialLoadResult {
        restartAfterInterrupt()
        let result = CredentialLoadResult.evaluate(started: started, readiness: credentialReadiness,
                                                   kind: kind, generation: credentialGeneration)
        DeliveryDiagnostics.shared.credentialEvent(kind: kind, stage: "load", code: result.diagnosticCode)
        return result
    }



    nonisolated func restartAndVerifyCredential(_ kind: CredentialKind) async -> CredentialCheckResult {
        io.cancel()
        return await restartAndCheck(kind)
    }

    private func restartAndCheck(_ kind: CredentialKind) -> CredentialCheckResult {
        let load = restartAndLoad(kind)
        guard load == .loaded else { return .init(code: load.diagnosticCode) }
        let checkID = UUID().uuidString.lowercased()
        writeLine(["credential_check": [
            "kind": kind.rawValue, "check_id": checkID,
            "generation": credentialGeneration, "allow_network": true,
        ]])
        responseDeadline = DaemonPipeIO.deadline(after: 20)
        guard let line = readLine() else {
            DeliveryDiagnostics.shared.credentialEvent(kind: kind, stage: "check", code: .backendUnavailable)
            return .init(code: .backendUnavailable)
        }
        let result = CredentialCheckResult.decode(line, kind: kind, checkID: checkID, generation: credentialGeneration)
        DeliveryDiagnostics.shared.credentialEvent(kind: kind, stage: "check", code: result.code)
        return result
    }

    private func start() {
        if started && process.isRunning { return }
        if process.isRunning { process.terminate() }   // 旧进程还活着(如上次读到坏行)→ 先杀,别叠出俩 daemon


        process = Process()
        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        io.reset()
        started = false
        credentialReadiness = nil
        credentialGeneration = UUID().uuidString.lowercased()

        let dir = Self.resolveProjectDir()
        vlog("Python 大脑目录:\(dir.path)")  // 看用的是哪份(环境变量/包内/开发目录),换机或打包后好排查
        process.executableURL = Self.resolvePythonExecutable(in: dir)

        process.arguments = ["-u", dir.appendingPathComponent("daemon.py").path]
        process.currentDirectoryURL = dir
        var environment = Self.daemonEnvironment()
        environment["LIANA_CREDENTIAL_GENERATION"] = credentialGeneration
        process.environment = environment   // 注入确定性能力、彼此分离的 BYOK 与云端配置；优先于开发 .env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice  // 丢弃 tqdm/警告
        do {
            try process.run()
            responseDeadline = DaemonPipeIO.deadline(after: 120)
            guard let line = readLine(), Self.isReadyMessage(line) else {
                failConnection()
                return
            }
            started = true
            if let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                credentialReadiness = object["credentials"] as? [String: Any]
            }
            vlog("守护进程就绪")
        } catch {
            vlog("守护进程启动失败 \(error)")
        }
    }

    nonisolated static func isReadyMessage(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return reply["ready"] as? Bool == true
    }




    func transcribe(
        path: String,
        style: String = "clean",
        smartEnhance: Bool = false,
        runID: String? = nil,
        fallbackReason: String? = nil,
        wait: DictationWait? = nil,
        onProgress: @Sendable (DictationProgress) -> Void = { _ in }
    ) -> String {
        if !started || !process.isRunning { start() }  // 死了就重起
        guard started else { return "" }

        var request: [String: Any] = ["path": path, "style": style]
        if smartEnhance {
            request["smart_enhance"] = true
            request["allow_network"] = true
        }
        if let runID, !runID.isEmpty { request["run_id"] = runID }
        if let fallbackReason, !fallbackReason.isEmpty {
            request["fallback_reason"] = fallbackReason
        }
        if smartEnhance, let wait { request["smart_progress"] = true; request["run_id"] = wait.runID.uuidString }
        writeLine(request)
        return readStreamResult(wait: smartEnhance ? wait : nil, onProgress: onProgress, onDelta: { _ in })
    }



    func learn(old: String, new: String, raw: String = "") -> [String] {
        if !started || !process.isRunning { start() }
        guard started else { return [] }
        writeLine(["learn": ["old": old, "new": new, "raw": raw]])
        guard
            let line = readLine(),
            let d = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let learned = obj["learned"] as? [String]
        else { return [] }
        return learned
    }




    func edit(selection: String, wavPath: String) -> (text: String, error: String?) {
        if !started || !process.isRunning { start() }
        guard started else { return ("", "daemon") }
        writeLine(["edit": ["selection": selection, "path": wavPath, "allow_network": true]])
        guard let line = readLine(), let d = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else {
            started = false                          // 读不到 → daemon 可能已死,下次重起
            return ("", "daemon")
        }
        if let inst = obj["instruction"] as? String, !inst.isEmpty {
            vlogContent("改写指令: \(inst)")           // 正文诊断默认关闭，用户明确配合排错时才打开
        }
        if let text = obj["text"] as? String { return (text, nil) }
        let err = (obj["error"] as? String) ?? "unknown"
        vlog("选中即改错误 \(err)")
        return ("", err)
    }


    func enhancePreview(
        selection: String,
        operation: EnhancementOperation
    ) -> EnhancementPreviewResult {

        guard !Task.isCancelled else {
            return .localFailure(original: selection, operation: operation, errorCode: "cancelled")
        }
        if !started || !process.isRunning { start() }
        guard started else {
            return .transportFailure(original: selection, operation: operation)
        }

        guard !Task.isCancelled else {
            return .localFailure(original: selection, operation: operation, errorCode: "cancelled")
        }
        writeLine([
            "enhance_preview": [
                "selection": selection,
                "operation": operation.rawValue,
                "allow_network": true,
            ],
        ])
        guard let line = readLine() else {
            started = false
            return .transportFailure(original: selection, operation: operation)
        }
        return .decode(
            line: line,
            original: selection,
            requestedOperation: operation
        )
    }



    func enhanceInstructionPreview(
        selection: String,
        wavPath: String
    ) -> EnhancementPreviewResult {
        if !started || !process.isRunning { start() }
        guard started else {
            return .transportFailure(original: selection, operation: .instruction)
        }

        writeLine([
            "enhance_instruction_preview": [
                "selection": selection,
                "path": wavPath,
                "allow_network": true,
            ],
        ])
        guard let line = readLine() else {
            started = false
            return .transportFailure(original: selection, operation: .instruction)
        }
        return .decode(
            line: line,
            original: selection,
            requestedOperation: .instruction
        )
    }




    func enroll(path: String) -> Bool {
        if !started || !process.isRunning { start() }
        guard started else { return false }
        writeLine(["enroll": path])
        guard let line = readLine(), let d = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return false }
        return (obj["enrolled"] as? Bool) ?? false
    }


    func speakerStatus() -> (enrolled: Bool, available: Bool) {
        if !started || !process.isRunning { start() }
        guard started else { return (false, false) }
        writeLine(["speaker": "status"])
        guard let line = readLine(), let d = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return (false, false) }
        return ((obj["enrolled"] as? Bool) ?? false, (obj["available"] as? Bool) ?? false)
    }


    func speakerClear() {
        guard started, process.isRunning else { return }
        writeLine(["speaker": "clear"])
        _ = readLine()
    }


    func setSpeaker(verify: Bool, threshold: Double) {
        guard started, process.isRunning else { return }
        writeLine(["speaker_config": ["verify": verify, "threshold": threshold]])
    }







    func streamStart(context: String = "") {
        if !started || !process.isRunning { start() }
        guard started else { return }
        writeLine(context.isEmpty ? ["stream": "start"]
                                  : ["stream": "start", "context": context])
    }


    func streamAudio(_ pcm: [Int16]) {
        guard started, process.isRunning else { return }
        let bytes = pcm.withUnsafeBufferPointer { Data(buffer: $0) }  // int16 小端字节
        writeLine(["stream": "audio", "pcm": bytes.base64EncodedString()])
    }



    func streamStop(
        style: String = "clean",
        smartEnhance: Bool = false,
        runID: String? = nil,
        wait: DictationWait? = nil,
        onProgress: @Sendable (DictationProgress) -> Void = { _ in },
        onDelta: @Sendable (String) -> Void
    ) -> String {
        guard started, process.isRunning else { return "" }
        var request: [String: Any] = ["stream": "stop", "style": style]
        if smartEnhance {
            request["smart_enhance"] = true
            request["allow_network"] = true
        }
        if let runID, !runID.isEmpty { request["run_id"] = runID }
        if smartEnhance, let wait { request["smart_progress"] = true; request["run_id"] = wait.runID.uuidString }
        writeLine(request)
        return readStreamResult(wait: smartEnhance ? wait : nil, onProgress: onProgress, onDelta: onDelta)
    }


    func streamCancel() {
        guard started, process.isRunning else { return }
        writeLine(["stream": "cancel"])
    }


    func setEngine(_ engine: String) {
        if !started || !process.isRunning { start() }
        guard started else { return }
        writeLine(["set_engine": engine])
    }


    private func writeLine(_ obj: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: obj),
            let str = String(data: data, encoding: .utf8)
        else { return }
        responseDeadline = DaemonPipeIO.deadline(after: responseTimeout)
        if !io.write(Data((str + "\n").utf8), fd: stdinPipe.fileHandleForWriting.fileDescriptor,
                     until: DaemonPipeIO.deadline(after: 30)) { failConnection() }
    }



    private func readStreamResult(
        wait: DictationWait? = nil,
        onProgress: @Sendable (DictationProgress) -> Void = { _ in },
        onDelta: @Sendable (String) -> Void
    ) -> String {
        wait?.beginWaiting()
        defer {


            if wait?.endWaiting() == true, started {
                let raw = lastRaw
                failConnection()
                lastRaw = raw
            }
        }
        var typed = ""                               // 已敲出的部分:daemon 中途崩就返回它,别让上层整段重转造成重复
        func interrupted() -> String {
            failConnection()                         // 坏帧也必须关旧进程，不能留到下一次请求。
            if let draft = wait?.draft {
                wait?.markConnectionFailed()
                lastRaw = draft.raw                  // failConnection 清空后恢复本次独立快照。
                return draft.text                    // 草稿已有正文，不重跑 ASR／付费润色。
            }
            return typed
        }
        while true {
            guard
                let line = readLine(),
                let data = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return interrupted()
            }
            if obj["type"] as? String == "smart_progress" {
                guard let wait, let progress = wait.receive(obj) else { return interrupted() }

                responseDeadline = DaemonPipeIO.deadline(after: responseTimeout)
                onProgress(progress)
                continue
            }
            if let delta = obj["delta"] as? String {
                typed += delta
                onDelta(delta)                       // 边收边敲;continue 接着读下一块
                continue
            }
            if let wait, obj["text"] != nil {
                let receipt = obj["runtime_receipt"] as? [String: Any]
                guard wait.matches(receipt?["run_id"]) else { return interrupted() }
            }
            if obj["error"] != nil, wait?.draft != nil { return interrupted() }
            if obj["text"] == nil && obj["error"] == nil { return interrupted() }

            if let ta = obj["t_asr"] as? Double, let tp = obj["t_polish"] as? Double {
                let tl = obj["t_layout"] as? Double ?? 0
                let asr = (obj["asr"] as? String) ?? ""

                vlog("用时:转写 \(ta)s + 润色 \(tp)s + 排版 \(tl)s  [\(asr)]")
            }
            lastRaw = (obj["asr_raw"] as? String) ?? ""       // 存原始转写,供"编辑即学习"按原始形态记映射
            if !lastRaw.isEmpty {
                vlogContent("原始转写: \(lastRaw)")
            }
            recordRuntimeDiagnostics(obj)
            if let text = obj["text"] as? String { return text }
            if let err = obj["error"] as? String { vlog("守护进程错误 \(err)") }
            return typed
        }
    }


    private func recordRuntimeDiagnostics(_ obj: [String: Any]) {
        if let warn = obj["warn"] as? String, !warn.isEmpty {
            vlog("⚠️ \(warn)")
            Task { @MainActor in Toast.show("⚠️ " + warn, duration: 4.0) }
        }
        if let smart = obj["smart_enhancement"] as? [String: Any],
           let status = smart["status"] as? String,
           ["applied", "unchanged", "fallback"].contains(status) {
            let latency = (smart["latency_ms"] as? NSNumber)?.intValue ?? 0
            let defaults = UserDefaults.standard
            defaults.set(status, forKey: "lastSmartDictationStatus")
            defaults.set(latency, forKey: "lastSmartDictationLatencyMS")
            defaults.set(Date().timeIntervalSince1970, forKey: "lastSmartDictationAt")
            vlog("智能整理: \(status) · \(latency)ms")
            if let usage = smart["usage"] as? [String: Any] {
                let input = (usage["input_tokens"] as? NSNumber)?.intValue
                let output = (usage["output_tokens"] as? NSNumber)?.intValue
                let total = (usage["total_tokens"] as? NSNumber)?.intValue
                vlog("智能整理用量: input=\(input.map { String($0) } ?? "?") "
                     + "output=\(output.map { String($0) } ?? "?") "
                     + "total=\(total.map { String($0) } ?? "?")")
            }
            let issues = smart["validation_issues"] as? [String] ?? []
            let warnings = smart["validation_warnings"] as? [String] ?? []
            if !issues.isEmpty || !warnings.isEmpty {
                vlog("智能整理保护: issues=\(issues) warnings=\(warnings)")
            }
            if let local = obj["local_text"] as? String {
                vlogContent("确定性结果: \(local)")
            }
            if let candidate = obj["smart_candidate"] as? String {
                vlogContent("云端候选: \(candidate)")
            }
        }
        if let receipt = obj["runtime_receipt"] as? [String: Any] {
            let runID = receipt["run_id"] as? String ?? "-"
            let route = receipt["actual_route"] as? String ?? "-"
            let promptID = receipt["prompt_id"] as? String ?? "-"
            let promptSHA = receipt["prompt_sha256"] as? String ?? ""
            let prompt = promptSHA.isEmpty
                ? promptID
                : "\(promptID)@\(String(promptSHA.prefix(12)))"
            let fallback = receipt["fallback_reason"] as? String ?? "-"
            let finalStatus = receipt["final_status"] as? String ?? "-"
            vlog("运行回执: run=\(runID) route=\(route) prompt=\(prompt) "
                 + "fallback=\(fallback) final=\(finalStatus)")
        }
    }


    private func readLine() -> String? {
        guard let line = io.readLine(fd: stdoutPipe.fileHandleForReading.fileDescriptor, until: responseDeadline) else {
            failConnection()
            return nil
        }
        return line
    }

    private func failConnection() {
        started = false
        lastRaw = ""
        io.cancel()
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        vlog("后台通信中断或超时；下次请求重新启动")
    }
}
