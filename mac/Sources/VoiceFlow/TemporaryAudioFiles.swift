import Foundation


final class TemporaryAudioFiles: @unchecked Sendable {
    static let shared = TemporaryAudioFiles()
    private let lock = NSLock()
    private var references: [URL: Int] = [:]
    private let directory: URL

    init(base: URL = FileManager.default.temporaryDirectory) {
        directory = base.appendingPathComponent("liana-audio-\(UUID().uuidString)", isDirectory: true)
    }

    func create() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        references[url] = 1
        return url
    }

    func retain(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        if let count = references[url] { references[url] = count + 1 }
    }

    func release(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        guard let count = references[url] else { return }
        if count > 1 { references[url] = count - 1; return }
        references.removeValue(forKey: url)
        try? FileManager.default.removeItem(at: url)
        if references.isEmpty { try? FileManager.default.removeItem(at: directory) }
    }

    func cleanup() {
        lock.lock(); defer { lock.unlock() }
        for url in references.keys { try? FileManager.default.removeItem(at: url) }
        references.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { cleanup() }
}
