import Foundation


@inline(__always)
func vlog(_ s: String) {
    FileHandle.standardError.write(Data(("VF: " + s + "\n").utf8))
}



private let contentDiagnosticsEnabled: Bool = {
    let value = ProcessInfo.processInfo.environment["LIANA_CONTENT_DIAGNOSTICS"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
    return ["1", "true", "yes", "on"].contains(value)
}()

@inline(__always)
func vlogContent(_ s: @autoclosure () -> String) {
    guard contentDiagnosticsEnabled else { return }
    vlog(s())
}
