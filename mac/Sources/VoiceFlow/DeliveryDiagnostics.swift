import Foundation
import Darwin



final class DeliveryDiagnostics: @unchecked Sendable {
    static let shared = DeliveryDiagnostics(enabled: AppDefaults.deliveryDiagnosticsEnabled())
    private let enabled: Bool
    private let directory: URL
    private let limit: Int
    private let queue = DispatchQueue(label: "com.voiceflow.delivery-diagnostics", qos: .utility)
    private let session = UUID().uuidString.lowercased()
    private var failure = false

    init(enabled: Bool, directory: URL? = nil, limit: Int = 2 * 1024 * 1024) {
        self.enabled = enabled
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceFlow/Diagnostics", isDirectory: true)
        self.limit = max(4096, limit)
    }


    static func fields(from trace: String) -> [String: String]? {
        let id = "[0-9a-fA-F-]{36}"
        let identifier = "[A-Za-z0-9._-]{1,128}"
        let schemas: [(String, String)] = [
            ("begin", "delivery=\(id) begin pid=[0-9]+ app=\(identifier) input_source=\(identifier) focused_element=(true|false) multiline=(true|false) source_utf16=[0-9]+ planned_parts=[0-9]+(?: transport=(process|override))?"),
            ("part", "delivery=\(id) part=[0-9]+ kind=(unicode|newline) utf16=[0-9]+ events_submitted=2"),
            ("end", "delivery=\(id) end status=(submitted_unverified|target_changed|event_unavailable|already_attempted) parts_submitted=[0-9]+ utf16_submitted=[0-9]+ key_events_submitted=[0-9]+ focus_ms=[0-9]+ elapsed_ms=[0-9]+"),
        ]
        guard trace.utf8.count < 1024, !trace.contains("\n"), !trace.contains("\r") else { return nil }
        for (event, pattern) in schemas {
            guard trace.range(of: "\\A" + pattern + "\\z", options: .regularExpression) != nil else { continue }
            var fields = ["event": event]
            for token in trace.split(separator: " ") {
                let pair = token.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
            }
            guard UUID(uuidString: fields["delivery"] ?? "") != nil else { return nil }
            return fields
        }
        return nil
    }

    func recordTrace(_ trace: String) {
        guard enabled, let fields = Self.fields(from: trace) else { return }
        record(fields)
    }

    func associate(run: UUID, history: UUID?, delivery: UUID) {
        record(["event": "association", "run": run.uuidString.lowercased(),
                "history": history?.uuidString.lowercased() ?? "-",
                "delivery": delivery.uuidString.lowercased()])
    }

    func started() { record(["event": "session_start"]) }
    func selfCheck() { record(["event": "diagnostics_self_check"]) }


    func credentialCheck(asrStatus: Int32, textStatus: Int32, keychainStatus: Int32) {
        record(["event": "credential_check", "asr_status": String(asrStatus),
                "text_status": String(textStatus), "keychain_status": String(keychainStatus)])
    }


    func credentialEvent(kind: CredentialKind, stage: String, osStatus: Int32? = nil, code: CredentialCheckCode? = nil) {
        guard ["read", "save", "readback", "load", "check"].contains(stage) else { return }
        var fields = ["event": "credential_state", "kind": kind.rawValue, "stage": stage]
        if let osStatus { fields["os_status"] = String(osStatus) }
        if let code { fields["code"] = code.rawValue }
        record(fields)
    }

    @discardableResult
    func flush() -> Bool { queue.sync { !failure } }

    private func record(_ fields: [String: String]) {
        guard enabled else { return }
        queue.async { [self] in
            var entry = fields
            entry["session"] = session
            entry["app_pid"] = String(ProcessInfo.processInfo.processIdentifier)
            entry["time"] = ISO8601DateFormatter().string(from: Date())
            do {
                var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
                data.append(10)
                try append(data)
            } catch {
                failure = true

                vlog("交付诊断写入失败；不能依赖本次轨迹。")
            }
        }
    }

    private func append(_ data: Data) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else { throw CocoaError(.fileWriteNoPermission) }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent("delivery.jsonl").path
        let fd = open(path, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, fchmod(fd, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }

        if info.st_size + Int64(data.count) > limit {
            guard ftruncate(fd, 0) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
    }
}
