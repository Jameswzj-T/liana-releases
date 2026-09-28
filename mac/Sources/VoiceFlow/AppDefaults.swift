import Foundation
import Security

struct LLMProviderConfiguration: Equatable {
    let baseURL: String
    let model: String
}



final class ProviderCredentialCache: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: KeychainReadResult] = [:]

    func result(for provider: String, reload: Bool = false, loader: () -> KeychainReadResult) -> KeychainReadResult {
        lock.lock()
        defer { lock.unlock() }
        if !reload, let result = results[provider] { return result }
        let result = loader()
        results[provider] = result
        return result
    }

    func value(for provider: String, loader: () -> String?) -> String? {
        result(for: provider) {
            let value = loader()
            return KeychainReadResult(value: value, status: value == nil ? errSecItemNotFound : errSecSuccess)
        }.value
    }

    func store(_ value: String?, for provider: String) {
        lock.lock()
        defer { lock.unlock() }

        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        results[provider] = KeychainReadResult(value: clean, status: clean.isEmpty ? errSecItemNotFound : errSecSuccess)
    }
}

struct CredentialSaveResult: Equatable {
    let writeStatus: OSStatus
    let verificationStatus: OSStatus?
    var verified: Bool { writeStatus == errSecSuccess && verificationStatus == errSecSuccess }
    var status: OSStatus { writeStatus == errSecSuccess ? verificationStatus ?? errSecDecode : writeStatus }
}


enum LLMProviderPreset: String, CaseIterable {
    case deepseek
    case qwen
    case doubao
    case mimo
    case glm
    case glm53
    case gemini
    case custom

    static func normalizedID(_ value: String) -> String {
        LLMProviderPreset(rawValue: value)?.rawValue ?? LLMProviderPreset.custom.rawValue
    }



    static func credentialID(_ value: String) -> String {
        switch LLMProviderPreset(rawValue: value) ?? .custom {
        case .glm53:
            return LLMProviderPreset.glm.rawValue
        default:
            return normalizedID(value)
        }
    }

    static func configuration(
        for provider: String,
        customBaseURL: String,
        customModel: String
    ) -> LLMProviderConfiguration {
        switch LLMProviderPreset(rawValue: provider) ?? .custom {
        case .deepseek:
            return LLMProviderConfiguration(
                baseURL: "https://api.deepseek.com",
                model: "deepseek-v4-flash"
            )
        case .qwen:
            return LLMProviderConfiguration(
                baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                model: "qwen3.7-flash"
            )
        case .doubao:
            return LLMProviderConfiguration(
                baseURL: "https://ark.cn-beijing.volces.com/api/v3",
                model: "doubao-seed-2-0-mini-260428"
            )
        case .mimo:
            return LLMProviderConfiguration(
                baseURL: "https://api.xiaomimimo.com/v1",
                model: "mimo-v2.5"
            )
        case .glm:
            return LLMProviderConfiguration(
                baseURL: "https://api.z.ai/api/paas/v4",
                model: "glm-4.7-flash"
            )
        case .glm53:
            return LLMProviderConfiguration(
                baseURL: "https://api.z.ai/api/paas/v4",
                model: "glm-5.3-flash"
            )
        case .gemini:
            return LLMProviderConfiguration(
                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                model: "gemini-3.5-flash-lite"
            )
        case .custom:
            return LLMProviderConfiguration(
                baseURL: customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                model: customModel.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

enum AppDefaults {

    static func deliveryDiagnosticsEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleMarked: Bool = Bundle.main.object(forInfoDictionaryKey: "LianaDeliveryDiagnostics") as? Bool ?? false
    ) -> Bool {
        if let explicit = environment["LIANA_DELIVERY_DIAGNOSTICS"], ["0", "1"].contains(explicit) {
            return explicit == "1"
        }
        return bundleMarked
    }



    static let polishKeyAccount = "LLM_API_KEY"
    static let legacyPolishKeyOwnerDefaultsKey = "legacyPolishKeyOwner"
    private static let polishKeyCache = ProviderCredentialCache()
    static let asrCloudKeyAccount = "ASR_CLOUD_KEY"
    static let currentASREngine = "qwen3_06"

    static let defaultLLMProvider = LLMProviderPreset.qwen.rawValue

    private static let retiredASREngines: Set<String> = [
        "glmasr", "qwen3", "sensevoice", "whisper", "distil", "zipformer", "auto"
    ]

    static var values: [String: Any] {
        [
            "asrCloud": false,
            "contextAware": true,
            "appAwareStyle": true,
            "polishStyle": "clean",
            "polishShortToo": false,
            "textEnhancementEnabled": false,
            "smartDictationEnabled": false,
            "llmProvider": defaultLLMProvider,
            "asrEngine": currentASREngine,
            "noiseReduction": false,
        ]
    }

    static func register(into defaults: UserDefaults = .standard) {
        defaults.register(defaults: values)

        if let engine = defaults.string(forKey: "asrEngine"), retiredASREngines.contains(engine) {
            defaults.set(currentASREngine, forKey: "asrEngine")
        }
        migrateKnownCustomProvider(in: defaults)
    }



    static func migrateKnownCustomProvider(in defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: "llmProvider") == LLMProviderPreset.custom.rawValue else {
            return
        }
        let storedBase = (defaults.string(forKey: "llmBaseURL") ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
            .lowercased()
        let storedModel = (defaults.string(forKey: "polishModel") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !storedBase.isEmpty, !storedModel.isEmpty else { return }

        for preset in [
            LLMProviderPreset.glm,
            LLMProviderPreset.gemini,
            LLMProviderPreset.deepseek,
            LLMProviderPreset.qwen,
            LLMProviderPreset.doubao,
        ] {
            let expected = LLMProviderPreset.configuration(
                for: preset.rawValue,
                customBaseURL: "",
                customModel: ""
            )
            let expectedBase = expected.baseURL
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .lowercased()
            if storedBase == expectedBase, storedModel == expected.model.lowercased() {
                defaults.set(preset.rawValue, forKey: "llmProvider")
                if defaults.string(forKey: legacyPolishKeyOwnerDefaultsKey) == "custom" {
                    defaults.set(preset.rawValue, forKey: legacyPolishKeyOwnerDefaultsKey)
                }
                return
            }
        }
    }

    static func polishKeyAccount(for provider: String) -> String {
        "\(polishKeyAccount).\(LLMProviderPreset.credentialID(provider))"
    }

    static func prepareLegacyPolishKeyOwner(
        provider: String,
        defaults: UserDefaults = .standard
    ) {
        guard defaults.object(forKey: legacyPolishKeyOwnerDefaultsKey) == nil else { return }
        defaults.set(
            LLMProviderPreset.credentialID(provider),
            forKey: legacyPolishKeyOwnerDefaultsKey
        )
    }

    static func legacyPolishKeyBelongs(
        to provider: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.string(forKey: legacyPolishKeyOwnerDefaultsKey)
            == LLMProviderPreset.credentialID(provider)
    }

    static func configuredPolishKey(
        provider: String,
        defaults: UserDefaults = .standard
    ) -> String? {
        polishKeyState(provider: provider, defaults: defaults).value
    }

    static func polishKeyState(
        provider: String, defaults: UserDefaults = .standard,
        reload: Bool = false, allowInteraction: Bool = false,
        cache: ProviderCredentialCache? = nil,
        read: (String, Bool) -> KeychainReadResult = { Keychain.read($0, allowInteraction: $1) }
    ) -> KeychainReadResult {
        let providerID = LLMProviderPreset.credentialID(provider)
        prepareLegacyPolishKeyOwner(provider: providerID, defaults: defaults)
        let account = polishKeyAccount(for: providerID)
        var legacy = [account]
        if legacyPolishKeyBelongs(to: providerID, defaults: defaults) { legacy.append(polishKeyAccount) }
        return credentialState(account: account, legacy: legacy, defaults: defaults, reload: reload,
                               allowInteraction: allowInteraction, cache: cache, read: read)
    }

    static func asrCloudKeyState(
        defaults: UserDefaults = .standard, reload: Bool = false, allowInteraction: Bool = false,
        cache: ProviderCredentialCache? = nil,
        read: (String, Bool) -> KeychainReadResult = { Keychain.read($0, allowInteraction: $1) }
    ) -> KeychainReadResult {
        credentialState(account: asrCloudKeyAccount, legacy: [asrCloudKeyAccount], defaults: defaults,
                        reload: reload, allowInteraction: allowInteraction, cache: cache, read: read)
    }

    private static func credentialState(
        account: String, legacy: [String], defaults: UserDefaults, reload: Bool, allowInteraction: Bool,
        cache: ProviderCredentialCache?, read: (String, Bool) -> KeychainReadResult
    ) -> KeychainReadResult {
        (cache ?? polishKeyCache).result(for: account, reload: reload) {
            var state = read(account, allowInteraction)
            guard state.status == errSecItemNotFound,
                  !defaults.bool(forKey: "credentialVerified." + account) else { return state }
            for oldAccount in legacy where oldAccount != account {
                state = read(oldAccount, allowInteraction)

                if state.status != errSecItemNotFound { return state }
            }
            return state
        }
    }



    @discardableResult
    static func savePolishKey(
        _ value: String,
        provider: String,
        defaults: UserDefaults = .standard,
        cache: ProviderCredentialCache? = nil,
        write: (String, String) -> OSStatus = { Keychain.set($0, for: $1) },
        read: (String, Bool) -> KeychainReadResult = { Keychain.read($0, allowInteraction: $1) }
    ) -> CredentialSaveResult {
        let providerID = LLMProviderPreset.credentialID(provider)
        prepareLegacyPolishKeyOwner(provider: providerID, defaults: defaults)
        return saveCredential(value, account: polishKeyAccount(for: providerID), defaults: defaults,
                              cache: cache, write: write, read: read)
    }

    @discardableResult
    static func saveAsrCloudKey(
        _ value: String, defaults: UserDefaults = .standard, cache: ProviderCredentialCache? = nil,
        write: (String, String) -> OSStatus = { Keychain.set($0, for: $1) },
        read: (String, Bool) -> KeychainReadResult = { Keychain.read($0, allowInteraction: $1) }
    ) -> CredentialSaveResult {
        saveCredential(value, account: asrCloudKeyAccount, defaults: defaults, cache: cache, write: write, read: read)
    }

    private static func saveCredential(
        _ value: String, account: String, defaults: UserDefaults, cache: ProviderCredentialCache?,
        write: (String, String) -> OSStatus, read: (String, Bool) -> KeychainReadResult
    ) -> CredentialSaveResult {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return CredentialSaveResult(writeStatus: errSecParam, verificationStatus: nil) }
        let status = write(clean, account)
        guard status == errSecSuccess else { return CredentialSaveResult(writeStatus: status, verificationStatus: nil) }




        let verified = read(account, true)
        let verification = verified.status == errSecSuccess && verified.value != clean ? errSecDecode : verified.status
        if verification == errSecSuccess {
            defaults.set(true, forKey: "credentialVerified." + account)
            (cache ?? polishKeyCache).store(clean, for: account)
        }
        return CredentialSaveResult(writeStatus: status, verificationStatus: verification)
    }

    static func credentialEnvironment(
        base: [String: String],
        polishKey: String?,
        asrCloudKey: String?,
        textEnhancementEnabled: Bool = false,
        smartDictationEnabled: Bool = false,
        cloudTranscriptionEnabled: Bool = false
    ) -> [String: String] {
        var env = base

        env["ASR_PROVIDER"] = "local"
        env["ASR_E2E"] = "0"
        env["ASR_API_KEY"] = ""
        env["ASR_CLOUD"] = cloudTranscriptionEnabled ? "1" : "0"
        let polish = (polishKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)


        env[polishKeyAccount] = polish
        let transcription = (asrCloudKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        env[asrCloudKeyAccount] = transcription


        env["POLISH_DISABLE"] = "1"
        env["TEXT_ENHANCEMENT_ENABLED"] = textEnhancementEnabled ? "1" : "0"
        env["SMART_DICTATION_ENABLED"] = smartDictationEnabled ? "1" : "0"


        env["VOCAB_CONTEXT"] = "1"
        env["CORRECTIONS_HARD"] = "1"
        return env
    }
}
