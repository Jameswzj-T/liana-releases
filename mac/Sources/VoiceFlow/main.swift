import AppKit

signal(SIGPIPE, SIG_IGN)   // 写已死 daemon 的 stdin 不崩:忽略 SIGPIPE(write 改为返回 EPIPE、被 try? 吞掉)



let args = CommandLine.arguments

if args.count == 2, args[1] == "diagnostics-self-check" {
    guard AppDefaults.deliveryDiagnosticsEnabled() else { exit(2) }
    DeliveryDiagnostics.shared.selfCheck()
    exit(DeliveryDiagnostics.shared.flush() ? 0 : 1)
} else if args.count == 2, args[1] == "credential-save-check" {


    guard Bundle.main.object(forInfoDictionaryKey: "LianaDeliveryDiagnostics") as? Bool == true,
          isatty(STDIN_FILENO) == 0 else { exit(2) }
    let input = FileHandle.standardInput.readData(ofLength: 8193)
    guard input.count <= 8192,
          let payload = try? JSONSerialization.jsonObject(with: input) as? [String: String],
          Set(payload.keys) == ["asr", "text"],
          let asrValue = payload["asr"], !asrValue.isEmpty,
          let textValue = payload["text"], !textValue.isEmpty else { exit(2) }
    let asr = AppDefaults.saveAsrCloudKey(asrValue)
    let text = AppDefaults.savePolishKey(textValue, provider: "qwen")
    print("asr_write=\(asr.writeStatus) asr_verify=\(asr.verificationStatus ?? -1) text_write=\(text.writeStatus) text_verify=\(text.verificationStatus ?? -1)")
    exit(asr.verified && text.verified ? 0 : 1)
} else if args.count == 2, args[1] == "credential-read-check" {

    guard AppDefaults.deliveryDiagnosticsEnabled() else { exit(2) }
    let provider = UserDefaults.standard.string(forKey: "llmProvider") ?? AppDefaults.defaultLLMProvider
    let asr = AppDefaults.asrCloudKeyState(reload: true)
    let text = AppDefaults.polishKeyState(provider: provider, reload: true)
    let health = Keychain.defaultKeychainHealth()
    DeliveryDiagnostics.shared.credentialCheck(asrStatus: asr.status, textStatus: text.status, keychainStatus: health)
    print("asr_status=\(asr.status) text_status=\(text.status) keychain_status=\(health)")
    exit(DeliveryDiagnostics.shared.flush() && asr.value != nil && text.value != nil ? 0 : 1)
} else if args.count >= 3, args[1] == "transcribe" {
    let sem = DispatchSemaphore(value: 0)
    let t = Transcriber()
    Task.detached {
        let text = await t.transcribe(path: args[2])
        print("=== RESULT ===")
        print(text)
        print("==============")
        sem.signal()
    }
    sem.wait()
} else if args.count >= 2, args[1] == "preview" {

    _ = NSApplication.shared   // 初始化 AppKit,供 ImageRenderer 用
    let which = args.count >= 3 ? args[2] : "hud"
    let out = args.count >= 4 ? args[3] : "/tmp/vf_preview.png"
    MainActor.assumeIsolated {
        DesignPreview.render(which: which, to: out)
    }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate


    app.setActivationPolicy(.regular)
    app.run()
}
