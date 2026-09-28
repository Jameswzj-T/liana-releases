import XCTest
import Security
@testable import Liana



final class CredentialCombinationTests: XCTestCase {
    func testUnconfiguredBothOffAreNeutralAndIndependent() {
        var state = CredentialPresentationState()
        state.observeRead(hasValue: false, status: errSecItemNotFound)
        for usage: CredentialUsage in [.asr(enabled: false), .text(automatic: false, selected: false)] {
            XCTAssertEqual(CredentialPresentation.make(state: state, usage: usage).tone, .neutral)
        }
        state.observeRead(hasValue: false, status: errSecAuthFailed)
        XCTAssertTrue(CredentialPresentation.make(state: state, usage: .text(automatic: false, selected: false)).headline.zh.contains("文字功能关闭"))
        XCTAssertEqual(CredentialPresentation.make(state: state, usage: .asr(enabled: true)).tone, .warning)
    }

    func testLegacyQueryStillUsesOriginalStoreAndNoninteractiveReads() {
        let out = Keychain.read("synthetic-only", copy: { query, _ in
            let q = query as! [String: Any]
            XCTAssertEqual(q[kSecAttrService as String] as? String, "com.voiceflow.mac")
            XCTAssertNil(q[kSecUseDataProtectionKeychain as String])
            XCTAssertEqual(q[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
            return errSecItemNotFound
        })
        XCTAssertEqual(out.status, errSecItemNotFound)
        XCTAssertNil(out.value)
    }

    func testLegacyWriteDoesNotDeleteOrMigrate() {
        var calls: [String] = []
        let result = Keychain.set("synthetic-only", for: "synthetic-only", update: { query, _ in
            calls.append("update")
            let q = query as! [String: Any]
            XCTAssertEqual(q[kSecAttrService as String] as? String, "com.voiceflow.mac")
            XCTAssertNil(q[kSecUseDataProtectionKeychain as String])
            return errSecItemNotFound
        }, add: { _ in calls.append("add"); return errSecSuccess }, delete: { _ in
            XCTFail("No deletion authorized"); return errSecParam
        })
        XCTAssertEqual(result, errSecSuccess)
        XCTAssertEqual(calls, ["update", "add"])
    }

    @MainActor
    func testFailedSaveSkipsServiceAndPreservesManualTestAfterCancel() async {
        var state = CredentialPresentationState()
        state.observeRead(hasValue: true, status: errSecSuccess)
        state.beginSave()
        var serviceCalls = 0
        let outcome = await CredentialSetupFlow.run(save: {
            CredentialSaveResult(writeStatus: errSecAuthFailed, verificationStatus: nil)
        }, verify: { serviceCalls += 1; return .init(code: .ok) }, phase: { _ in })
        state.saveFailed(write: outcome.saved.writeStatus, readback: outcome.saved.verificationStatus)
        XCTAssertNil(outcome.check)
        XCTAssertEqual(serviceCalls, 0)
        XCTAssertEqual(CredentialPresentation.make(state: state, usage: .asr(enabled: true)).tone, .warning)
        state.dismissAction()
        XCTAssertTrue(state.canManuallyTestStoredKey)
    }

    @MainActor
    func testStorageSuccessThenNetworkFailureNeverClaimsServiceSuccess() async {
        var phases: [String] = []
        var state = CredentialPresentationState()
        let outcome = await CredentialSetupFlow.run(save: {
            .init(writeStatus: errSecSuccess, verificationStatus: errSecSuccess)
        }, verify: { .init(code: .network) }, phase: { phase in
            switch phase {
            case .saving: phases.append("saving"); state.beginSave()
            case .checking: phases.append("checking"); state.storageVerified()
            case .finished(let result): phases.append("finished"); state.serviceFinished(code: result.code.rawValue)
            }
        })
        XCTAssertTrue(outcome.saved.verified)
        XCTAssertEqual(phases, ["saving", "checking", "finished"])
        XCTAssertTrue(state.readableStorage)
        XCTAssertEqual(CredentialPresentation.make(state: state, usage: .asr(enabled: true)).tone, .warning)

        var reopened = CredentialPresentationState()
        reopened.observeRead(hasValue: true, status: errSecSuccess)
        XCTAssertNil(reopened.serviceCode)
        XCTAssertEqual(CredentialPresentation.make(state: reopened, usage: .asr(enabled: true)).tone, .neutral)
    }
}
