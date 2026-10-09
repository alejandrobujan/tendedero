// A tiny assertion/runner adapter for the same XCTest cases, when only Apple's
// Command Line Tools are installed. No dependencies or user clipboard access.
import Foundation
import os

class HistoryTestCase {}
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
enum HistoryTestRunner {
    @MainActor static func main() {
        let tests = ImageHistoryTests()
        let cases: [(String, () throws -> Void)] = [
            ("testDefaultAndInvalidRetention", tests.testDefaultAndInvalidRetention),
            ("testEveryRetentionChoicePersists", tests.testEveryRetentionChoicePersists),
            ("testNewestFirstAndDuplicatesDoNotRenew", tests.testNewestFirstAndDuplicatesDoNotRenew),
            ("testRestartPreservesOrderAndDates", tests.testRestartPreservesOrderAndDates),
            ("testExpiryDeletesOwnedCopiesButKeepsOriginals", tests.testExpiryDeletesOwnedCopiesButKeepsOriginals),
            ("testCutoffAndFreshImage", tests.testCutoffAndFreshImage),
            ("testShorterRetentionAppliesImmediately", tests.testShorterRetentionAppliesImmediately),
            ("testMissingFilesArePruned", tests.testMissingFilesArePruned),
            ("testLegacyMigrationRecoversOnlyOwnedFilesOnce", tests.testLegacyMigrationRecoversOnlyOwnedFilesOnce),
            ("testOrphanFilesExpireAndLookalikesStay", tests.testOrphanFilesExpireAndLookalikesStay),
            ("testSymlinkIsNeverFollowedOrDeleted", tests.testSymlinkIsNeverFollowedOrDeleted),
            ("testSymlinkedInboxDoesNotDeleteFiles", tests.testSymlinkedInboxDoesNotDeleteFiles),
            ("testCorruptMetadataCanRecoverLegacyList", tests.testCorruptMetadataCanRecoverLegacyList),
            ("testLineKeepsMoreThanScreenCapacityAndBoundsThumbnails", tests.testLineKeepsMoreThanScreenCapacityAndBoundsThumbnails),
            ("testWheelBothDirectionsAndResizeClamp", tests.testWheelBothDirectionsAndResizeClamp),
            ("testNewCaptureReturnsToNewestAndExpiredLineClamps", tests.testNewCaptureReturnsToNewestAndExpiredLineClamps),
            ("testScrollLoadsVisibleThumbnailsAndEvictsOffscreenImages", tests.testScrollLoadsVisibleThumbnailsAndEvictsOffscreenImages),
            ("testLayoutStartsLeftAndLastCardIsReachable", tests.testLayoutStartsLeftAndLastCardIsReachable),
            ("testPanelRoutesSyntheticWheelLocally", tests.testPanelRoutesSyntheticWheelLocally),
            ("testClearPersistsAndDoesNotReimportOrphans", tests.testClearPersistsAndDoesNotReimportOrphans),
            ("testNestedClipboardNamesAreNotDeleted", tests.testNestedClipboardNamesAreNotDeleted),
            ("testMenuOffersEveryDurationAndChecksSelection", tests.testMenuOffersEveryDurationAndChecksSelection)
        ]
        for (name, test) in cases {
            let before = assertionFailures
            do { try test() }
            catch { fail("\(name): \(error)", file: #filePath, line: #line) }
            if assertionFailures == before { print("PASS \(name)") }
        }
        print("\(cases.count) synthetic history/layout cases, \(assertionFailures) failures")
        if assertionFailures != 0 { exit(1) }
    }
}
