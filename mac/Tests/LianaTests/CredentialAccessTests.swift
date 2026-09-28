import XCTest
import Security
@testable import Liana


final class CredentialAccessTests: XCTestCase {
    @MainActor
    func testAuthorizeOnlyReloadsButNeverTestsService() async {
        var calls: [String] = []
        var state = CredentialPresentationState()
        state.storageVerified(); state.serviceFinished(code: "ok")
        state.beginAuthorization()
        let result = await CredentialAccessFlow.run(action: .authorizeOnly, isCurrent: { true }, read: {
            calls.append("read"); return .init(value: "synthetic-only", status: 0)
        }, observed: { read in
            state.authorizationFinished(hasValue: read.value != nil, status: read.status, willTestService: false)
            XCTAssertEqual(state.activity, .loading)
            XCTAssertNil(state.serviceCode)
            XCTAssertFalse(CredentialPresentation.make(state: state, usage: .asr(enabled: false)).headline.en.contains("testing the service"))
        }, reload: { calls.append("load"); return .loaded }, verify: {
            XCTFail("Authorize-only must not call provider verification"); return .init(code: .ok)
        })
        XCTAssertEqual(calls, ["read", "load"])
        XCTAssertEqual(result.load, .loaded)
        XCTAssertNil(result.check)
        state.localLoadFinished(code: result.load!.rawValue)
        XCTAssertEqual(state.activity, .idle)
        XCTAssertTrue(state.readableStorage)
        XCTAssertNil(state.serviceCode)
        let view = CredentialPresentation.make(state: state, usage: .asr(enabled: false))
        XCTAssertEqual(view.tone, .neutral)
        XCTAssertTrue(view.headline.en.contains("no cloud test"))
        XCTAssertEqual(view.summary, CredentialUsage.asr(enabled: false).offSummary)
    }

    @MainActor
    func testExplicitServiceTestKeepsOneVerificationAndNoExtraReload() async {
        var calls: [String] = []
        let result = await CredentialAccessFlow.run(action: .testService, isCurrent: { true }, read: {
            calls.append("read"); return .init(value: "synthetic-only", status: 0)
        }, observed: { _ in }, reload: {
            XCTFail("Service verifier already reloads exactly once"); return .loaded
        }, verify: { calls.append("test"); return .init(code: .network) })
        XCTAssertEqual(calls, ["read", "test"])
        XCTAssertEqual(result.check?.code, .network)
        XCTAssertNil(result.load)
    }

    @MainActor
    func testFailedReadsNeverReloadOrTestAndNeverClaimSendingStopped() async {
        for action: CredentialAccessAction in [.authorizeOnly, .testService] {
            for status: Int32 in [-25293, -25308, -128, -25300, -34018] {
                var state = CredentialPresentationState()
                state.storageVerified(); state.serviceFinished(code: "ok"); state.beginAuthorization()
                let result = await CredentialAccessFlow.run(action: action, isCurrent: { true }, read: {
                    .init(status: status)
                }, observed: { read in
                    state.authorizationFinished(hasValue: read.value != nil, status: read.status, willTestService: action == .testService)
                }, reload: { XCTFail("Failed read must not reload"); return .loaded }, verify: {
                    XCTFail("Failed read must not call the provider"); return .init(code: .ok)
                })
                XCTAssertNil(result.load); XCTAssertNil(result.check); XCTAssertNil(state.serviceCode)
                XCTAssertEqual(state.activity, .idle)
                XCTAssertTrue(state.requiresRouteConfirmation)
                XCTAssertFalse(state.canManuallyTestStoredKey)
                let view = CredentialPresentation.make(state: state, usage: .text(automatic: true, selected: true))
                XCTAssertTrue(view.summary.en.contains("unconfirmed"))
                XCTAssertFalse(view.summary.en.contains("not active"))
                XCTAssertEqual(view.showRecovery, status != -34018 && status != -25300)
            }
        }
    }

    func testPassiveOffStatesExposeLocalRecoveryWithoutWarning() {
        for usage: CredentialUsage in [.asr(enabled: false), .text(automatic: false, selected: false)] {
            for status: Int32 in [-25293, -25308, -128, -34018, -25300] {
                var state = CredentialPresentationState()
                state.observeRead(hasValue: false, status: status)
                let view = CredentialPresentation.make(state: state, usage: usage)
                XCTAssertEqual(view.tone, .neutral)
                XCTAssertEqual(view.summary, usage.offSummary)
                XCTAssertEqual(view.showRecovery, status != -34018 && status != -25300)
            }
        }
    }

    @MainActor
    func testLocalLoadFailuresPreserveReadableKeyWithoutCloudSuccess() async {
        for load: CredentialLoadResult in [.backendUnavailable, .credentialNotLoaded] {
            var state = CredentialPresentationState()
            state.beginAuthorization()
            let result = await CredentialAccessFlow.run(action: .authorizeOnly, isCurrent: { true }, read: {
                .init(value: "synthetic-only", status: 0)
            }, observed: { read in
                state.authorizationFinished(hasValue: read.value != nil, status: read.status, willTestService: false)
            }, reload: { load }, verify: { XCTFail("Local failure is not a cloud retry"); return .init(code: .ok) })
            state.localLoadFinished(code: result.load!.rawValue)
            XCTAssertTrue(state.readableStorage)
            XCTAssertTrue(state.requiresRouteConfirmation)
            XCTAssertNil(state.serviceCode)
            XCTAssertNil(result.check)
            let view = CredentialPresentation.make(state: state, usage: .asr(enabled: true))
            XCTAssertEqual(view.tone, .warning)
            XCTAssertTrue(view.showRecovery)
            XCTAssertFalse(view.headline.en.contains("passed"))
            XCTAssertTrue(view.details!.en.contains("No cloud test"))
        }
    }

    func testLocalReadinessRequiresCurrentGenerationAndMatchingKind() {
        let valid: [String: Any] = ["generation": "current", "asr_key_loaded": true, "text_key_loaded": false]
        XCTAssertEqual(CredentialLoadResult.evaluate(started: false, readiness: valid, kind: .asr, generation: "current"), .backendUnavailable)
        XCTAssertEqual(CredentialLoadResult.evaluate(started: true, readiness: nil, kind: .asr, generation: "current"), .credentialNotLoaded)
        XCTAssertEqual(CredentialLoadResult.evaluate(started: true, readiness: valid, kind: .asr, generation: "old"), .credentialNotLoaded)
        XCTAssertEqual(CredentialLoadResult.evaluate(started: true, readiness: valid, kind: .asr, generation: ""), .credentialNotLoaded)
        XCTAssertEqual(CredentialLoadResult.evaluate(started: true, readiness: valid, kind: .text, generation: "current"), .credentialNotLoaded)
        XCTAssertEqual(CredentialLoadResult.evaluate(started: true, readiness: valid, kind: .asr, generation: "current"), .loaded)
    }

    @MainActor
    func testSupersededBeforeOrDuringReadSkipsReloadAndProvider() async {
        for initiallyCurrent in [false, true] {
            var current = initiallyCurrent
            var reads = 0
            let result = await CredentialAccessFlow.run(action: .testService, isCurrent: { current }, read: {
                reads += 1; current = false; return .init(value: "synthetic-only", status: 0)
            }, observed: { _ in XCTFail("Stale read must not update the current card") }, reload: {
                XCTFail("Stale read must not reload"); return .loaded
            }, verify: { XCTFail("Stale read must not test a provider"); return .init(code: .ok) })
            XCTAssertTrue(result.superseded)
            XCTAssertEqual(reads, initiallyCurrent ? 1 : 0)
            XCTAssertNil(result.load); XCTAssertNil(result.check)
        }
    }

    @MainActor
    func testSupersededAfterAwaitDropsResult() async {
        for action: CredentialAccessAction in [.authorizeOnly, .testService] {
            var current = true
            let result = await CredentialAccessFlow.run(action: action, isCurrent: { current }, read: {
                .init(value: "synthetic-only", status: 0)
            }, observed: { _ in }, reload: { current = false; return .loaded }, verify: {
                current = false; return .init(code: .ok)
            })
            XCTAssertTrue(result.superseded)
            XCTAssertNil(result.load); XCTAssertNil(result.check)
        }
    }

    func testExplicitInteractionReloadReplacesOnlyMatchingCache() {
        let cache = ProviderCredentialCache()
        var reads = 0
        let failed = { reads += 1; return KeychainReadResult(status: errSecAuthFailed) }
        XCTAssertNil(cache.result(for: "asr", loader: failed).value)
        XCTAssertNil(cache.result(for: "asr", loader: failed).value)
        XCTAssertEqual(reads, 1)
        let restored = cache.result(for: "asr", reload: true) {
            reads += 1
            return Keychain.read("synthetic-only", allowInteraction: true, copy: { query, pointer in
                let q = query as! [String: Any]
                XCTAssertEqual(q[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIAllow as String)
                XCTAssertEqual(q[kSecAttrAccount as String] as? String, "synthetic-only")
                pointer?.pointee = Data("synthetic-only".utf8) as CFData
                return errSecSuccess
            })
        }
        XCTAssertNotNil(restored.value); XCTAssertEqual(reads, 2)
        XCTAssertNotNil(cache.result(for: "asr", loader: failed).value)
        XCTAssertNil(cache.result(for: "text", loader: failed).value)
        XCTAssertEqual(reads, 3)
    }

    func testReopeningDoesNotRememberLocalOrCloudTestResults() {
        var state = CredentialPresentationState()
        state.authorizationFinished(hasValue: true, status: 0, willTestService: false)
        state.localLoadFinished(code: "loaded")
        state.observeRead(hasValue: true, status: 0)
        XCTAssertNil(state.localLoadCode); XCTAssertNil(state.serviceCode)
        let view = CredentialPresentation.make(state: state, usage: .asr(enabled: true))
        XCTAssertTrue(view.headline.en.contains("not tested this session"))
    }

    @MainActor
    func testFailedAuthorizationUncertaintySurvivesSettingsRecreationAndEmptySave() {
        let tracker = CredentialAccessUncertainty()
        let identity = CredentialAccessUncertainty.identity(asr: false, provider: "qwen")
        tracker.mark(identity)
        var state = CredentialPresentationState()
        state.authorizationFinished(hasValue: false, status: errSecAuthFailed, willTestService: false)
        state.requireInput()
        XCTAssertTrue(state.requiresRouteConfirmation)

        state = CredentialPresentationState()
        state.observeRead(hasValue: false, status: errSecAuthFailed, backendUnconfirmed: tracker.contains(identity))
        XCTAssertTrue(state.requiresRouteConfirmation)
        let view = CredentialPresentation.make(state: state, usage: .text(automatic: true, selected: false))
        XCTAssertTrue(view.summary.en.contains("unconfirmed"))
        XCTAssertFalse(view.summary.en.contains("not active"))
        XCTAssertFalse(tracker.contains(CredentialAccessUncertainty.identity(asr: true, provider: "qwen")))
        XCTAssertFalse(tracker.contains(CredentialAccessUncertainty.identity(asr: false, provider: "mimo")))
        tracker.confirm(identity)
        state.observeRead(hasValue: true, status: 0, backendUnconfirmed: tracker.contains(identity))
        XCTAssertFalse(state.requiresRouteConfirmation)
        XCTAssertFalse(CredentialAccessUncertainty().contains(identity), "New process does not inherit the previous daemon")
    }

    func testCancelUnconfirmedReplacementKeepsLocalRecoveryWhileOff() {
        for usage: CredentialUsage in [.asr(enabled: false), .text(automatic: false, selected: false)] {
            for status: Int32 in [-25293, -25308, -128, -34018] {
                var state = CredentialPresentationState()
                state.observeRead(hasValue: true, status: 0)
                state.beginSave(); state.saveFailed(write: 0, readback: status); state.dismissAction()
                let view = CredentialPresentation.make(state: state, usage: usage)
                XCTAssertEqual(view.showRecovery, status != -34018)
                XCTAssertEqual(view.tone, .neutral)
            }
        }
    }

    func testReadableCacheDoesNotEraseUnconfirmedBackendOnReentry() {
        var state = CredentialPresentationState()
        state.observeRead(hasValue: true, status: 0, backendUnconfirmed: true)
        XCTAssertTrue(state.requiresRouteConfirmation)
        let view = CredentialPresentation.make(state: state, usage: .asr(enabled: false))
        XCTAssertEqual(view.tone, .neutral)
        XCTAssertTrue(view.showRecovery)
        XCTAssertTrue(view.headline.en.contains("unconfirmed"))
    }

    func testLocalLoadEvidenceDoesNotConfuseTransportFailureWithProviderReply() {
        for code in CredentialCheckCode.allCases {
            let uncertain: [CredentialCheckCode] = [.backendUnavailable, .credentialNotLoaded, .configurationChanged, .invalidResponse, .notAuthorized]
            let result = CredentialAccessOutcome(check: .init(code: code))
            XCTAssertEqual(result.confirmsLocalLoad, !uncertain.contains(code))
            var state = CredentialPresentationState()
            state.authorizationFinished(hasValue: true, status: 0)
            state.serviceFinished(code: code.rawValue)
            XCTAssertEqual(state.backendUnconfirmed, uncertain.contains(code))
            for usage: CredentialUsage in [.asr(enabled: false), .asr(enabled: true),
                                          .text(automatic: false, selected: false),
                                          .text(automatic: true, selected: true)] {
                let view = CredentialPresentation.make(state: state, usage: usage)
                XCTAssertEqual(view.showRecovery, uncertain.contains(code))

                if uncertain.contains(code) {
                    XCTAssertFalse(view.headline.en.contains("No cloud test"))
                    XCTAssertFalse(view.summary.en.contains("No cloud test"))
                }
            }
        }
    }

    @MainActor
    func testUnconfirmedSaveSurvivesStaleReadableCacheAndViewRecreation() {
        for result in [CredentialSaveResult(writeStatus: 0, verificationStatus: -25293),
                       CredentialSaveResult(writeStatus: 0, verificationStatus: -34018),
                       CredentialSaveResult(writeStatus: -34018, verificationStatus: nil)] {
            let tracker = CredentialAccessUncertainty()
            let identity = CredentialAccessUncertainty.identity(asr: true, provider: "qwen")
            tracker.recordSaveFailure(identity, result: result)
            tracker.mark(identity) // Beginning a later action must not erase the earlier evidence.
            var state = CredentialPresentationState()
            state.observeRead(hasValue: true, status: 0, backendUnconfirmed: tracker.contains(identity))
            tracker.restoreSaveEvidence(identity, into: &state)
            XCTAssertFalse(state.readableStorage, "Old cache does not verify the newly written key")
            XCTAssertTrue(state.requiresRouteConfirmation)
            XCTAssertNil(state.actionFailure)
            let signing = result.writeStatus == -34018 || result.verificationStatus == -34018
            let view = CredentialPresentation.make(state: state, usage: .asr(enabled: false))
            XCTAssertEqual(view.showRecovery, !signing)
            XCTAssertEqual(view.tone, .neutral)
            if result.writeStatus == 0 && !signing {
                XCTAssertEqual(state.storage, .writtenButUnconfirmed(readback: result.verificationStatus))
                XCTAssertTrue(view.headline.en.contains("readable storage is not confirmed"))
            }


            tracker.readSucceeded(identity)
            state.observeRead(hasValue: true, status: 0, backendUnconfirmed: tracker.contains(identity))
            tracker.restoreSaveEvidence(identity, into: &state)
            XCTAssertTrue(state.readableStorage)
            XCTAssertTrue(state.requiresRouteConfirmation)
            tracker.confirm(identity)
            XCTAssertFalse(tracker.contains(identity))
        }
    }

    @MainActor
    func testFailedWriteKeepsOldKeyEvidenceAndDoesNotAffectOtherProvider() {
        let tracker = CredentialAccessUncertainty()
        let id = CredentialAccessUncertainty.identity(asr: false, provider: "qwen")
        tracker.recordSaveFailure(id, result: .init(writeStatus: -25293, verificationStatus: nil))
        XCTAssertFalse(tracker.contains(id), "A failed write alone does not change the old loaded key")
        tracker.recordSaveFailure(id, result: .init(writeStatus: 0, verificationStatus: -25293))
        var other = CredentialPresentationState()
        other.observeRead(hasValue: true, status: 0)
        tracker.restoreSaveEvidence(CredentialAccessUncertainty.identity(asr: false, provider: "mimo"), into: &other)
        XCTAssertTrue(other.readableStorage)
        XCTAssertFalse(other.requiresRouteConfirmation)
    }

    @MainActor
    func testCustomConfigurationEditInvalidatesLoadedStateWithoutServiceCall() {
        let tracker = CredentialAccessUncertainty()
        let id = CredentialAccessUncertainty.identity(asr: false, provider: "custom")
        var state = CredentialPresentationState()
        state.observeRead(hasValue: true, status: 0)
        state.localLoadFinished(code: "loaded")
        tracker.mark(id)
        state.configurationChanged(backendUnconfirmed: true)
        XCTAssertNil(state.localLoadCode); XCTAssertNil(state.serviceCode)
        XCTAssertTrue(state.requiresRouteConfirmation)
        XCTAssertTrue(CredentialPresentation.make(state: state, usage: .text(automatic: true, selected: false)).showRecovery)
        state = CredentialPresentationState()
        state.observeRead(hasValue: true, status: 0, backendUnconfirmed: tracker.contains(id))
        XCTAssertTrue(state.requiresRouteConfirmation)
    }
}
