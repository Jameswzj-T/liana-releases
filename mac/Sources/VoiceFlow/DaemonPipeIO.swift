import Foundation
import Darwin


final class DaemonPipeIO: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var buffer = Data()
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func reset() { lock.lock(); cancelled = false; lock.unlock(); buffer = Data() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    static func deadline(after seconds: Double) -> Double { ProcessInfo.processInfo.systemUptime + seconds }

    private func wait(_ fd: Int32, events: Int16, until deadline: Double) -> Bool {
        while !isCancelled {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&item, 1, Int32(min(50, max(1, remaining * 1000))))
            if result > 0 { return item.revents & (events | Int16(POLLHUP)) != 0 }
            if result < 0 && errno != EINTR { return false }
        }
        return false
    }

    func readLine(fd: Int32, until deadline: Double) -> String? {
        while !isCancelled {
            if let index = buffer.firstIndex(of: 10) {
                let data = buffer.prefix(upTo: index)
                let result = String(data: data, encoding: .utf8)
                buffer.removeSubrange(...index)
                return result
            }
            guard buffer.count < 8 * 1024 * 1024, wait(fd, events: Int16(POLLIN), until: deadline) else { return nil }
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { buffer.append(contentsOf: bytes.prefix(count)) }
            else if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            else { return nil }
        }
        return nil
    }

    func write(_ data: Data, fd: Int32, until deadline: Double) -> Bool {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        return data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard wait(fd, events: Int16(POLLOUT), until: deadline) else { return false }
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                else { return false }
            }
            return true
        }
    }
}
