//
//  LogCleanupBugTests.swift
//  AudiobookshelfUnitTests
//
//  Regression coverage for two latent bugs in Database.cleanExpiredLogs that mask
//  each other, so neither can be fixed alone: fixing the unit mismatch without
//  fixing the detached-delete turns silent log growth into a launch crash.
//  These tests pin down the current behavior; a fix for either must revisit both.
//

import XCTest
import RealmSwift
@testable import Audiobookshelf

final class LogCleanupBugTests: XCTestCase {

    /// Bug A -- unit mismatch. AbsLogger.saveLogEntry stores timestamps in
    /// MILLISECONDS (`Int(Date().timeIntervalSince1970 * 1000)`), but
    /// Database.cleanExpiredLogs compares them against a cutoff in SECONDS
    /// (`Int(keepLogCutoff.timeIntervalSince1970)`). Nothing is ever expired.
    func testExpiredLogIsNeverDetectedAsExpired() {
        let now = Date()
        let tenDaysAgo = now.addingTimeInterval(-10 * 24 * 3600)

        let storedTimestamp = Int(tenDaysAgo.timeIntervalSince1970 * 1000)   // as written
        let cutoff = Int(now.addingTimeInterval(-48 * 3600).timeIntervalSince1970) // as compared

        XCTAssertFalse(storedTimestamp < cutoff,
                       "A 10-day-old log is NOT detected as expired: stored=\(storedTimestamp)ms vs cutoff=\(cutoff)s")
        XCTAssertTrue(storedTimestamp / 1000 < cutoff,
                      "With matching units the same log IS correctly detected as expired")
    }

    /// Bug B -- getAllLogs() returns detached (unmanaged) copies via toArray(),
    /// and cleanExpiredLogs hands those straight to realm.delete(). Deleting an
    /// unmanaged object is a precondition failure that `try?` cannot catch.
    /// Asserting they are unmanaged proves it without crashing the runner.
    func testGetAllLogsReturnsUnmanagedObjects() throws {
        let config = Realm.Configuration(inMemoryIdentifier: "LogCleanupBugTests-\(UUID().uuidString)")
        let realm = try Realm(configuration: config)

        try realm.write {
            let entry = LogEntry()
            entry.tag = "test"
            entry.level = "info"
            entry.message = "hello"
            entry.timestamp = Int(Date().timeIntervalSince1970 * 1000)
            realm.add(entry)
        }

        let managed = realm.objects(LogEntry.self)
        XCTAssertNotNil(managed.first?.realm, "sanity: directly fetched objects are managed")

        let detached: [LogEntry] = managed.toArray()
        XCTAssertEqual(detached.count, 1)
        XCTAssertNil(detached.first?.realm,
                     "toArray() detaches -- realm.delete() on these is a precondition failure")
    }
}
