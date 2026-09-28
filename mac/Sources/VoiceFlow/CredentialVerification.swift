import Foundation

enum CredentialKind: String, Sendable { case text, asr }

enum CredentialCheckCode: String, Sendable, CaseIterable {
    case ok
    case backendUnavailable = "backend_unavailable"
    case credentialNotLoaded = "credential_not_loaded"
    case configurationChanged = "configuration_changed"
    case invalidResponse = "invalid_response"
    case notAuthorized = "network_not_authorized"
    case authFailed = "provider_auth_failed"
    case timeout = "provider_timeout"
    case network = "provider_network_error"
    case rateLimited = "provider_rate_limited"
    case balance = "provider_balance_exhausted"
    case quota = "provider_quota_exhausted"
    case unavailable = "provider_unavailable"
    case highTraffic = "provider_high_traffic"
    case modelUnavailable = "provider_model_not_available"
    case badRequest = "provider_bad_request"
    case policyLimited = "provider_policy_limited"
    case invalidProviderResponse = "provider_invalid_response"
    case truncated = "provider_output_truncated"
    case failed = "provider_failed"

    var message: String {
        switch self {
        case .ok:
            return L("已保存，后台已加载，服务测试通过 ✓", "Saved, loaded, and service test passed ✓")
        case .backendUnavailable:
            return L("Key 已保存，但后台未就绪或已超时。请稍候，点击“重新测试”。", "Key saved, but the backend is not ready or timed out. Wait briefly, then test again.")
        case .credentialNotLoaded:
            return L("Key 已保存，但后台未取得凭据。请点击“重新授权并测试”。", "Key saved, but the backend did not load it. Authorize and test again.")
        case .configurationChanged:
            return L("配置已改变，本次测试不代表当前配置。请重新测试。", "Configuration changed; this test does not verify the current settings. Test again.")
        case .authFailed:
            return L("Key 已保存，但服务拒绝访问。请检查 Key、对应供应商和模型权限；单纯等待不会解决。", "Key saved, but access was rejected. Check the key, provider, and model permissions; waiting alone will not resolve this.")
        case .balance, .quota:
            return L("Key 已保存，但账户余额或额度不足，请到供应商处检查。", "Key saved, but the account has insufficient balance or quota. Check your provider account.")
        case .timeout, .network:
            return L("Key 已保存，但网络测试未完成。请检查网络或代理，稍后手动重试。", "Key saved, but the network test did not complete. Check your network or proxy, then retry manually.")
        case .rateLimited, .unavailable, .highTraffic:
            return L("Key 已保存，但服务暂时繁忙或限流。请稍候再测试；不会自动重试。", "Key saved, but the service is busy or rate-limited. Wait and test again; there are no automatic retries.")
        case .modelUnavailable, .badRequest, .policyLimited:
            return L("Key 已保存，但当前模型或请求配置不可用，请检查供应商、模型与账户权限。", "Key saved, but the model or request configuration is unavailable. Check the provider, model, and account permissions.")
        default:
            return L("Key 已保存，但测试未通过。请重新测试；若持续失败，请检查配置。", "Key saved, but the test did not pass. Test again; if it keeps failing, check the configuration.")
        }
    }
}

struct CredentialCheckResult: Equatable, Sendable {
    let code: CredentialCheckCode
    var verified: Bool { code == .ok }

    static func decode(_ line: String, kind: CredentialKind, checkID: String, generation: String) -> Self {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let check = object["credential_check"] as? [String: Any],
              check["kind"] as? String == kind.rawValue,
              check["check_id"] as? String == checkID,
              check["generation"] as? String == generation,
              let raw = check["code"] as? String,
              let code = CredentialCheckCode(rawValue: raw) else { return .init(code: .invalidResponse) }
        return .init(code: code)
    }

    static func keyLoaded(in readiness: [String: Any]?, kind: CredentialKind, generation: String) -> Bool {
        guard let readiness, !generation.isEmpty,
              readiness["generation"] as? String == generation else { return false }
        return readiness[kind.rawValue + "_key_loaded"] as? Bool == true
    }
}

enum CredentialSetupPhase { case saving, checking, finished(CredentialCheckResult) }

struct CredentialSetupOutcome {
    let saved: CredentialSaveResult
    let check: CredentialCheckResult?
}



@MainActor
enum CredentialSetupFlow {
    static func run(
        save: () async -> CredentialSaveResult,
        verify: () async -> CredentialCheckResult,
        phase: (CredentialSetupPhase) -> Void
    ) async -> CredentialSetupOutcome {
        phase(.saving)
        let saved = await save()
        guard saved.verified else { return .init(saved: saved, check: nil) }
        phase(.checking)
        let check = await verify()
        phase(.finished(check))
        return .init(saved: saved, check: check)
    }
}
