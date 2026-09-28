import Foundation

enum CredentialAccessAction { case authorizeOnly, testService }



@MainActor
final class CredentialAccessUncertainty {
    static let shared = CredentialAccessUncertainty()
    private var pending: Set<String> = []


    private var unconfirmedSaves: [String: CredentialSaveResult] = [:]
    static func identity(asr: Bool, provider: String) -> String {
        asr ? "asr" : "text:" + LLMProviderPreset.credentialID(provider)
    }
    func mark(_ identity: String) { pending.insert(identity) }
    func recordSaveFailure(_ identity: String, result: CredentialSaveResult) {
        guard result.writeStatus == 0 || result.writeStatus == -34018 || result.verificationStatus == -34018 else { return }
        pending.insert(identity)
        unconfirmedSaves[identity] = result
    }
    func readSucceeded(_ identity: String) { unconfirmedSaves.removeValue(forKey: identity) }
    func restoreSaveEvidence(_ identity: String, into state: inout CredentialPresentationState) {
        guard let result = unconfirmedSaves[identity] else { return }
        state.saveFailed(write: result.writeStatus, readback: result.verificationStatus)
        state.dismissAction()
    }
    func confirm(_ identity: String) {
        pending.remove(identity)
        unconfirmedSaves.removeValue(forKey: identity)
    }
    func contains(_ identity: String) -> Bool { pending.contains(identity) }
}


enum CredentialLoadResult: String, Sendable {
    case loaded, backendUnavailable = "backend_unavailable", credentialNotLoaded = "credential_not_loaded"

    static func evaluate(started: Bool, readiness: [String: Any]?, kind: CredentialKind,
                         generation: String) -> Self {
        guard started else { return .backendUnavailable }
        return CredentialCheckResult.keyLoaded(in: readiness, kind: kind, generation: generation)
            ? .loaded : .credentialNotLoaded
    }

    var diagnosticCode: CredentialCheckCode {
        switch self {
        case .loaded: return .ok
        case .backendUnavailable: return .backendUnavailable
        case .credentialNotLoaded: return .credentialNotLoaded
        }
    }
}

struct CredentialAccessOutcome {
    var load: CredentialLoadResult?
    var check: CredentialCheckResult?
    var superseded = false
    var confirmsLocalLoad: Bool {
        if load == .loaded { return true }
        guard let check else { return false }
        switch check.code {
        case .backendUnavailable, .credentialNotLoaded, .configurationChanged, .invalidResponse, .notAuthorized:
            return false
        default: return true // A typed provider result is only obtained after local readiness passed.
        }
    }
}



@MainActor
enum CredentialAccessFlow {
    static func run(
        action: CredentialAccessAction,
        isCurrent: () -> Bool,
        read: () async -> KeychainReadResult,
        observed: (KeychainReadResult) -> Void,
        reload: () async -> CredentialLoadResult,
        verify: () async -> CredentialCheckResult
    ) async -> CredentialAccessOutcome {
        guard isCurrent() else { return .init(superseded: true) }
        let state = await read()
        guard isCurrent() else { return .init(superseded: true) }
        observed(state)
        guard state.value != nil else { return .init() }
        switch action {
        case .authorizeOnly:
            let load = await reload()
            return isCurrent() ? .init(load: load) : .init(superseded: true)
        case .testService:
            let check = await verify()
            return isCurrent() ? .init(check: check) : .init(superseded: true)
        }
    }
}
