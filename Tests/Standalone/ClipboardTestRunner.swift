// A tiny assertion/runner adapter for the same XCTest cases, when only Apple's
// Command Line Tools are installed. No dependencies or user clipboard access.
import Foundation
import os

class ClipboardTestCase {}
let log = Logger(subsystem: "local.clipboard-tests", category: "synthetic")
private var assertionFailures = 0

private struct UnwrapFailure: Error {}

private func fail(_ message: String, file: StaticString, line: UInt) {
    assertionFailures += 1
    print("FAIL \(file):\(line): \(message)")
}

func XCTAssertEqual<T: Equatable>(_ actual: @autoclosure () throws -> T,
    _ expected: @autoclosure () throws -> T, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line) {
    do {
        let a = try actual(), b = try expected()
        if a != b { fail("\(a) != \(b) \(message)", file: file, line: line) }
    } catch { fail("Unexpected error: \(error) \(message)", file: file, line: line) }
}

func XCTAssertTrue(_ value: @autoclosure () -> Bool, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line) {
    if !value() { fail("Expected true \(message)", file: file, line: line) }
}

func XCTAssertFalse(_ value: @autoclosure () -> Bool, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line) {
    if value() { fail("Expected false \(message)", file: file, line: line) }
}

func XCTAssertNil(_ value: @autoclosure () throws -> Any?, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try value() != nil { fail("Expected nil \(message)", file: file, line: line) }
    } catch { fail("Unexpected error: \(error) \(message)", file: file, line: line) }
}

func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else {
        fail("Expected a value", file: file, line: line)
        throw UnwrapFailure()
    }
    return value
}

@main
enum ClipboardTestRunner {
    @MainActor
    static func main() {
        let tests = ClipboardWatcherTests()
        let cases: [(String, () throws -> Void)] = [
            ("disabled watcher has no access", tests.testDisabledWatcherNeverReadsClipboardOrCreatesFolder),
            ("enable skips old image", tests.testEnablingSkipsExistingImage),
            ("PNG unchanged and captured once", tests.testPNGIsSavedOnceAndClipboardRemainsUnchanged),
            ("TIFF converts to PNG", tests.testTIFFConvertsToPNGWithoutChangingClipboard),
            ("multiple representations captured once", tests.testMultipleRepresentationsAndItemsProduceOneCapture),
            ("own copies skipped", tests.testOwnCopyIsSkippedAndNextExternalImageIsAccepted),
            ("privacy markers on every item", tests.testPrivateMarkersOnAnyItemPreventAllImageReads),
            ("Finder file/icon excluded", tests.testFileURLAndFinderIconAreSkippedWithoutReadingEither),
            ("unsupported/empty clipboard excluded", tests.testUnsupportedAndEmptyClipboardAreIgnored),
            ("stop/restart baseline", tests.testStopAndRestartSkipImagesCopiedWhileDisabled),
            ("start is idempotent", tests.testStartingTwiceDoesNotResetBaselineOrDuplicateTimer),
            ("metadata race discarded", tests.testClipboardChangeDuringMetadataReadIsDiscarded),
            ("data race discarded", tests.testClipboardChangeDuringDataReadIsDiscarded),
            ("invalid image and TIFF fallback", tests.testInvalidImageIsNotWrittenAndValidTIFFFallbackWorks),
            ("type and resource limits", tests.testValidationRejectsEmptyOversizedAndMislabeledData),
            ("storage failure preserves clipboard", tests.testStorageFailureDoesNotHangOrModifyClipboard),
            ("unique private files", tests.testDistinctCopiesUseUniquePrivateFiles)
        ]
        for (name, test) in cases {
            let before = assertionFailures
            do { try test() }
            catch { fail("\(name): \(error)", file: #filePath, line: #line) }
            if assertionFailures == before { print("PASS \(name)") }
        }
        print("\(cases.count) synthetic cases, \(assertionFailures) failures")
        if assertionFailures != 0 { exit(1) }
    }
}
