

struct CredentialCopy: Equatable {
    let zh: String
    let en: String
    init(_ zh: String, _ en: String) { self.zh = zh; self.en = en }
}

enum CredentialUsage: Equatable {
    case asr(enabled: Bool)
    case text(automatic: Bool, selected: Bool)
    var enabled: Bool {
        switch self {
        case .asr(let enabled): return enabled
        case .text(let automatic, let selected): return automatic || selected
        }
    }
    var offSummary: CredentialCopy {
        switch self {
        case .asr: return .init("云端转写关闭，继续使用本地转写。", "Cloud transcription is off; transcription stays local.")
        case .text: return .init("文字整理功能关闭；普通听写不发送给文字模型。", "Text features are off; dictation is not sent to the text model.")
        }
    }
    var offUnconfirmedHeadline: CredentialCopy {
        switch self {
        case .asr: return .init("云端转写关闭；Key 状态尚未确认。", "Cloud transcription is off; key status is unconfirmed.")
        case .text: return .init("文字功能关闭；Key 状态尚未确认。", "Text features are off; key status is unconfirmed.")
        }
    }
    var unavailableSummary: CredentialCopy {
        switch self {
        case .asr: return .init("云端转写尚未生效：没有可读取的 Key，当前仍使用本地转写。", "Cloud transcription is not active: no readable key is available, so transcription stays local.")
        case .text(let automatic, let selected):
            if automatic && selected { return .init("自动整理与选区改写尚未生效：没有可读取的 Key；听写保留转写文字。", "Automatic refinement and selected-text rewriting are not active: no readable key is available; dictation keeps the transcript.") }
            if automatic { return .init("自动整理尚未生效：没有可读取的 Key；听写保留转写文字。", "Automatic refinement is not active: no readable key is available; dictation keeps the transcript.") }
            return .init("选区改写尚未生效：没有可读取的 Key；不影响独立的转写功能。", "Selected-text rewriting is not active: no readable key is available; the separate transcription feature is unaffected.")
        }
    }
    var verifiedSummary: CredentialCopy {
        if !enabled { return offSummary }
        switch self {
        case .asr: return .init("本卡片的云端转写服务测试通过；云端识别失败仍回到本地。文字模型需另行验证。", "This cloud transcription service passed its test; recognition failures still fall back locally. The text model is checked separately.")
        case .text: return .init("本卡片的文字模型服务测试通过；按现有文字功能开关使用。云端转写需另行验证。", "This text model service passed its test and follows the existing text-feature switches. Cloud transcription is checked separately.")
        }
    }
}

struct CredentialPresentationState: Equatable {
    enum Storage: Equatable {
        case unknown, missing, readable, unavailable(Int32)
        case writtenButUnconfirmed(readback: Int32?)
    }
    enum Activity: Equatable { case idle, saving, authorizing, loading, checking }
    enum ActionFailure: Equatable {
        case emptyInput
        case save(write: Int32, readback: Int32?)
        case authorize(Int32)
    }
    private(set) var storage: Storage = .unknown
    private(set) var activity: Activity = .idle
    private(set) var actionFailure: ActionFailure?

    private(set) var serviceCode: String?

    private(set) var localLoadCode: String?
    private(set) var backendUnconfirmed = false
    private(set) var signingAuthorizationMissing = false
    var readableStorage: Bool { storage == .readable && !signingAuthorizationMissing }
    var requiresRouteConfirmation: Bool {
        if backendUnconfirmed { return true }
        if case .authorize = actionFailure { return true }
        if let localLoadCode, localLoadCode != "loaded" { return true }
        if case .writtenButUnconfirmed = storage { return true }
        return signingAuthorizationMissing && storage == .readable
    }
    var canManuallyTestStoredKey: Bool {
        guard !signingAuthorizationMissing else { return false }
        if case .writtenButUnconfirmed = storage { return true }
        return readableStorage
    }

    mutating func observeRead(hasValue: Bool, status: Int32, backendUnconfirmed: Bool = false) {
        self.backendUnconfirmed = backendUnconfirmed
        signingAuthorizationMissing = !hasValue && status == -34018
        storage = hasValue ? .readable : (status == -25300 ? .missing : .unavailable(status))
        activity = .idle
        actionFailure = nil
        serviceCode = nil
        localLoadCode = nil
    }
    mutating func requireInput() { activity = .idle; actionFailure = .emptyInput }
    mutating func beginSave() { activity = .saving; actionFailure = nil; serviceCode = nil; localLoadCode = nil }
    mutating func beginAuthorization() { activity = .authorizing; actionFailure = nil; serviceCode = nil; localLoadCode = nil }
    mutating func storageVerified() {
        signingAuthorizationMissing = false
        storage = .readable; activity = .checking; actionFailure = nil; serviceCode = nil; localLoadCode = nil
    }
    mutating func saveFailed(write: Int32, readback: Int32?) {
        signingAuthorizationMissing = write == -34018 || readback == -34018
        activity = .idle; actionFailure = .save(write: write, readback: readback); serviceCode = nil; localLoadCode = nil


        if write == 0 { storage = .writtenButUnconfirmed(readback: readback) }
    }
    mutating func authorizationFinished(hasValue: Bool, status: Int32, willTestService: Bool = true) {
        observeRead(hasValue: hasValue, status: status, backendUnconfirmed: true)
        if hasValue { activity = willTestService ? .checking : .loading }
        else { actionFailure = .authorize(status) }
    }
    mutating func localLoadFinished(code: String) { activity = .idle; localLoadCode = code; serviceCode = nil; backendUnconfirmed = code != "loaded" }
    mutating func serviceFinished(code: String) {
        activity = .idle; actionFailure = nil; serviceCode = code; localLoadCode = nil
        backendUnconfirmed = ["backend_unavailable", "credential_not_loaded", "configuration_changed", "invalid_response", "network_not_authorized"].contains(code)
    }
    mutating func dismissAction() { actionFailure = nil }
    mutating func configurationChanged(backendUnconfirmed: Bool = false) {
        activity = .idle; actionFailure = nil; serviceCode = nil; localLoadCode = nil
        self.backendUnconfirmed = self.backendUnconfirmed || backendUnconfirmed
    }

}

struct CredentialPresentation: Equatable {
    enum Tone: Equatable { case neutral, progress, success, warning }
    let headline: CredentialCopy
    let summary: CredentialCopy
    let tone: Tone
    let details: CredentialCopy?
    let showRecovery: Bool

    static func make(state: CredentialPresentationState, usage: CredentialUsage) -> Self {
        let readable = state.readableStorage
        let baseSummary: CredentialCopy
        if !usage.enabled { baseSummary = usage.offSummary }
        else if state.requiresRouteConfirmation {
            baseSummary = .init("后台凭据状态尚未确认；本次未验证云端服务，不能据此判断已停止发送。", "Backend credential state is unconfirmed; the cloud service was not verified. This does not confirm that sending has stopped.")
        } else if case .save(let write, _) = state.actionFailure, write != 0, readable {
            baseSummary = .init("此次更换未完成；原 Key 状态没有重新核验，新输入未应用或测试。", "Replacement did not complete; the existing key was not reverified. The new input was not applied or tested.")
        } else { baseSummary = (
            readable
            ? .init("Key 可读取；服务是否可用以测试结果为准。", "The key can be read; service availability depends on its test result.")
            : usage.unavailableSummary
        ) }
        func result(_ headline: CredentialCopy, _ tone: Tone = .neutral,
                    details: CredentialCopy? = nil, recovery: Bool = false,
                    summary: CredentialCopy? = nil) -> Self {
            .init(headline: headline, summary: summary ?? baseSummary, tone: tone, details: details, showRecovery: recovery)
        }
        switch state.activity {
        case .saving:
            return result(.init("正在保存并核对；如有系统授权窗口，请先处理…", "Saving and verifying storage; respond to any system permission prompt…"), .progress)
        case .authorizing:
            return result(.init("正在请求读取授权；如有系统窗口，请先处理…", "Requesting access; respond to any system permission prompt…"), .progress)
        case .loading:
            return result(.init("Key 可读取，正在重新加载后台；不进行云端测试…", "The key is readable. Reloading the backend without a cloud test…"), .progress)
        case .checking:
            return result(.init("Key 已保存并可读取，正在测试服务…", "Key saved and readable; testing the service…"), .progress)
        case .idle: break
        }
        if let failure = state.actionFailure {
            switch failure {
            case .emptyInput:
                return result(.init("请先粘贴 Key；尚未保存或测试。", "Paste a key first; nothing has been saved or tested."), .neutral)
            case .save(let write, let readback):
                if write == -34018 || readback == -34018 {
                    let storageCopy = write == 0
                        ? CredentialCopy("已写入，但未能确认可读取；输入已保留，暂未测试服务。", "Written, but readable storage is not confirmed; input retained and service not tested.")
                        : CredentialCopy("没有保存成功；输入已保留。", "Not saved; your input is retained.")
                    return result(.init(storageCopy.zh + signingFailure.zh, storageCopy.en + " " + signingFailure.en),
                        .warning, details: readDetails(-34018))
                }
                let headline: CredentialCopy = write == 0
                    ? .init("已写入，但未能确认可读取；输入已保留，暂未测试服务。", "Written, but readable storage is not confirmed; input retained and service not tested.")
                    : .init("没有保存成功；输入已保留，请检查系统授权。", "Not saved; your input is retained. Check system authorization.")
                let readbackText = readback.map(String.init) ?? "not_run"
                return result(headline, .warning,
                    details: .init("本机保存状态：\(write)；读回状态：\(readbackText)。这不是云端 API 的返回。不会为排错自动删除钥匙串条目。", "Local save status: \(write); read-back status: \(readbackText). This is not a cloud API response. Keychain entries are not automatically deleted for troubleshooting."), recovery: true)
            case .authorize(let status):
                if status == -34018 { return result(signingFailure, .warning, details: readDetails(status)) }
                return result(status == -25300
                    ? .init("没有找到已保存的 Key；请粘贴后保存。", "No saved key was found; paste a key and save it.")
                    : .init("暂时无法读取 Key；请完成系统授权后再试。", "The key could not be read; complete system authorization and try again."),
                    .warning, details: readDetails(status), recovery: status != -25300)
            }
        }
        if let code = state.serviceCode {
            if code == "ok" {
                return result(.init("Key 已保存，服务测试通过。", "Key saved; service test passed."), .success,
                    summary: usage.verifiedSummary)
            }
            return result(serviceFailure(code), .warning,
                details: .init("服务测试结果：\(code)。Key 的本机存储与云端可用性是两个独立状态。", "Service test result: \(code). Local credential storage and cloud availability are separate states."),
                recovery: state.requiresRouteConfirmation,
                summary: !usage.enabled ? usage.offSummary : .init("服务测试尚未通过；听写失败时仍保留转写结果，不自动重复请求。", "The service test did not pass; dictation keeps its transcript on failure and does not retry automatically."))
        }
        if let code = state.localLoadCode {
            if code == "loaded" {
                return result(.init("读取授权已恢复，后台已加载；未进行云端测试。", "Key access restored and backend loaded; no cloud test was made."))
            }
            return result(.init("Key 可读取，但后台尚未确认加载；可重新授权以重试加载。", "The key is readable, but backend loading was not confirmed. Authorize access again to reload."), .warning,
                details: .init("本机加载结果：\(code)。未发送云端测试，不会自动重试。", "Local load result: \(code). No cloud test was sent; there are no automatic retries."), recovery: true)
        }
        if state.signingAuthorizationMissing {
            return result(usage.enabled ? signingFailure : usage.offUnconfirmedHeadline,
                usage.enabled ? .warning : .neutral, details: readDetails(-34018))
        }
        switch state.storage {
        case .unknown:
            return result(.init("尚未检查 Key 状态。", "Key status has not been checked."))
        case .missing:
            return result(.init("未配置 Key，可继续使用本地转写。", "No key configured; local transcription remains available."))
        case .readable:
            if state.backendUnconfirmed {
                return result(.init("Key 可读取，但后台状态尚未确认；可重新授权以加载。", "The key is readable, but backend state is unconfirmed. Authorize access to reload."),
                    usage.enabled ? .warning : .neutral, recovery: true)
            }
            return result(.init("Key 已保存；本次尚未测试服务。", "Key saved; service not tested this session."))
        case .writtenButUnconfirmed(let readback):
            let status = readback.map(String.init) ?? "not_reported"
            return result(.init("新 Key 已写入，但尚未确认可读取。", "New key written, but readable storage is not confirmed."), usage.enabled ? .warning : .neutral,
                details: .init("写入成功；读回状态：\(status)。旧缓存不能证明新 Key 可读取；本次未测试服务。", "Write succeeded; read-back status: \(status). An old cache does not verify the new key; the service was not tested."), recovery: !state.signingAuthorizationMissing)
        case .unavailable(let status):

            if status == -34018 && usage.enabled {
                return result(signingFailure, .warning, details: readDetails(status))
            }
            return result(usage.enabled
                ? .init("暂时无法读取 Key，需要时可重新授权。", "The key cannot currently be read; authorize access when ready.")
                : usage.offUnconfirmedHeadline,
                usage.enabled ? .warning : .neutral, details: readDetails(status), recovery: status != -34018)
        }
    }

    private static var signingFailure: CredentialCopy {
        .init("当前应用缺少钥匙串签名授权；请使用正确签名的版本，重新解锁无法修复。", "This app lacks Keychain signing authorization. Use a correctly signed build; unlocking again cannot fix this.")
    }

    private static func readDetails(_ status: Int32) -> CredentialCopy {
        if status == -34018 {
            return .init("本机钥匙串状态：-34018，应用签名缺少所需授权。尚未向云端测试；不要反复解锁或重填 Key。", "Local Keychain status: -34018, required signing entitlement missing. No cloud test was made; do not repeatedly unlock or re-enter the key.")
        }
        return .init("本机钥匙串读取状态：\(status)。尚未向云端测试；读取失败不能证明 Key 未配置。", "Local Keychain read status: \(status). No cloud test was made; a failed read does not prove that no key is configured.")
    }

    private static func serviceFailure(_ code: String) -> CredentialCopy {
        switch code {
        case "provider_auth_failed": return .init("Key 已保存，但服务拒绝访问；请检查供应商与 Key 权限。", "Key saved, but access was rejected; check the provider and key permissions.")
        case "provider_network_error", "provider_timeout": return .init("Key 已保存，但网络测试未完成；请检查网络后手动重试。", "Key saved, but the network test did not complete; check the network and retry manually.")
        case "provider_balance_exhausted", "provider_quota_exhausted": return .init("Key 已保存，但账户余额或额度不足。", "Key saved, but account balance or quota is insufficient.")
        case "credential_not_loaded": return .init("Key 已保存，但后台未取得凭据；请先重新授权。", "Key saved, but the backend did not load it; authorize access again first.")
        case "backend_unavailable": return .init("Key 已保存，但后台尚未就绪；请稍候手动测试。", "Key saved, but the backend is not ready; wait briefly and test manually.")
        case "configuration_changed": return .init("配置已改变；本次测试不能代表当前配置，请重新测试。", "Configuration changed; this test does not verify current settings. Test again.")
        default: return .init("Key 已保存，但服务测试未通过；请检查配置后手动测试。", "Key saved, but the service test did not pass; check settings and test manually.")
        }
    }
}
