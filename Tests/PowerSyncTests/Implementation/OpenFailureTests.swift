import CSQLite
import Foundation
@testable import PowerSync
import Testing

/// Refuses the open of a database whose filename is exactly `refuse-open.db`, with its own
/// text and an extended result code, and leaves every other open alone.
///
/// Registered once and never cancelled. SQLite's auto-extension loader releases its mutex
/// between entries, and `sqlite3_cancel_auto_extension` fills the removed slot with the
/// last entry, so a cancel during another connection's open can move the PowerSync core
/// extension behind that loader's index and skip it for that connection. Registering the
/// same pointer twice is a no-op, so the registration is safe to repeat per test.
private let refusingExtension: @convention(c) (
    OpaquePointer?,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    OpaquePointer? // `const sqlite3_api_routines *`, an incomplete type to Swift
) -> Int32 = { database, errorMessage, _ in
    guard let database, let filename = sqlite3_db_filename(database, "main") else {
        return SQLITE_OK
    }
    guard (String(cString: filename) as NSString).lastPathComponent == "refuse-open.db" else {
        return SQLITE_OK
    }
    // SQLite frees the message with `sqlite3_free`, so it has to come from `sqlite3_malloc`;
    // `sqlite3_mprintf` is variadic and not callable from Swift.
    let text = "refused by OpenFailureTests"
    let length = text.utf8.count + 1
    if let errorMessage, let buffer = sqlite3_malloc(Int32(length)) {
        _ = text.withCString { memcpy(buffer, $0, length) }
        errorMessage.pointee = buffer.assumingMemoryBound(to: CChar.self)
    }
    return 3338 // SQLITE_IOERR_ACCESS: SQLITE_IOERR (10) | (13 << 8)
}

/// What a failed `sqlite3_open_v2` reports.
///
/// Every field the pool copies off the failed handle has a fixture that only the handle
/// can satisfy. A directory where the file should be fails with the same code and text
/// that `sqlite3_errstr` would give, so the assertion there is the operating-system errno,
/// which only `sqlite3_system_errno` holds. An auto extension that refuses the open fails
/// with an extended code and SQLite's own text, which the primary code and `sqlite3_errstr`
/// cannot produce.
struct OpenFailureTests {
    private static let schema = Schema(tables: [
        Table(name: "items", columns: [.text("name")]),
    ])

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("powersync-open-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Opens `path` through the pool and returns the SDK error the first query throws,
    /// or nil when the open succeeded.
    private func openFailure(at path: String) async -> PowerSyncError? {
        let database = PowerSyncDatabase(schema: Self.schema, dbFilename: path, logger: DefaultLogger())
        var failure: PowerSyncError?
        do {
            _ = try await database.get(sql: "SELECT 1", parameters: []) { try $0.getInt(index: 0) }
        } catch let error as PowerSyncError {
            failure = error
        } catch {
            Issue.record(error, "the open failed with something other than the SDK's error")
        }
        // `close()` initializes the pool before closing it, so on a database that could not
        // be opened it throws the same failure again. There is nothing to clean up but the
        // attempt.
        try? await database.close()
        return failure
    }

    @Test func aDirectoryWhereTheFileShouldBeReportsTheSystemErrno() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("open-failure.db", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

        let failure = await openFailure(at: path.path)
        let error = try #require(failure)
        guard case let .sqliteError(code, _, message, reason, _) = error else {
            Issue.record("expected sqliteError, got \(error)")
            return
        }
        #expect(code == SQLITE_CANTOPEN)
        #expect(reason == "unable to open database file")
        #expect(message?.contains(path.path) == true)
        // EISDIR. The primary code and the text above are what `sqlite3_errstr` gives too;
        // the errno is the one value that proves the handle was read before it was closed.
        #expect(message?.contains("errno \(EISDIR)") == true, "message: \(message ?? "nil")")
    }

    @Test func aRefusedExtensionLoadReportsTheExtendedCodeAndSQLitesText() async throws {
        let registered = sqlite3_auto_extension(
            unsafeBitCast(refusingExtension, to: (@convention(c) () -> Void).self)
        )
        #expect(registered == SQLITE_OK)
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("refuse-open.db").path

        let failure = await openFailure(at: path)
        let error = try #require(failure)
        guard case let .sqliteError(code, _, message, reason, _) = error else {
            Issue.record("expected sqliteError, got \(error)")
            return
        }
        // The full extended code. `sqlite3_open_v2` itself returns only the primary 10.
        #expect(code == 3338)
        #expect(reason == "automatic extension loading failed: refused by OpenFailureTests")
        #expect(message?.contains(path) == true)
    }
}
