import AppKit
import XCTest
@testable import Liana

final class CandidateCopyTests: XCTestCase {
    @MainActor
    func testCopyPreservesLanguagesQuotesDatesAndLineBreaks() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let candidate = "明天下午三点，Please keep ‘Image 2.5’.\nMeet at 15:00 📝"
        XCTAssertTrue(Paster.copyCandidate(candidate, on: board))
        XCTAssertEqual(board.string(forType: .string), candidate)
    }

    @MainActor
    func testEmptyCandidateDoesNotReplaceClipboard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("previous synthetic copy", forType: .string)
        let count = board.changeCount
        XCTAssertFalse(Paster.copyCandidate(" \n\t", on: board))
        XCTAssertEqual(board.changeCount, count)
        XCTAssertEqual(board.string(forType: .string), "previous synthetic copy")
    }

    @MainActor
    func testFailedWriteIsNotReportedAsCopied() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertFalse(Paster.copyCandidate("synthetic candidate", on: board, writeText: { _, _ in false }))
    }

    @MainActor
    func testConcurrentCopyIsKeptAndNotReportedAsOurSuccess() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertFalse(Paster.copyCandidate("our candidate", on: board, writeText: { board, _ in
            board.clearContents()
            return board.setString("other synthetic copy", forType: .string)
        }))
        XCTAssertEqual(board.string(forType: .string), "other synthetic copy")
    }
}
