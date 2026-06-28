import Foundation
import SQLite3
import Testing

@testable import Fenestra

@Suite("Cursor cookie safety")
struct CursorCookieStoreTests {
  @Test
  func onlyAcceptsCursorRegistrableDomains() {
    #expect(CursorBrowserCookieStore.isCursorDomain("cursor.com"))
    #expect(CursorBrowserCookieStore.isCursorDomain(".auth.cursor.com"))
    #expect(CursorBrowserCookieStore.isCursorDomain("cursor.sh"))
    #expect(!CursorBrowserCookieStore.isCursorDomain("evilcursor.com"))
    #expect(!CursorBrowserCookieStore.isCursorDomain("cursor.com.evil.example"))
  }

  @Test @MainActor
  func readsFirefoxSchemaAndRejectsLookalikeDomains() throws {
    let database = FileManager.default.temporaryDirectory
      .appending(path: "fenestra-firefox-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: database) }

    var db: OpaquePointer?
    let openStatus = sqlite3_open(database.path, &db)
    guard openStatus == SQLITE_OK else {
      throw ProviderFailure.unavailable("Could not create Firefox fixture")
    }
    defer {
      if let db {
        sqlite3_close(db)
      }
    }
    try execute(
      db,
      """
      CREATE TABLE moz_cookies (name TEXT, value TEXT, host TEXT);
      INSERT INTO moz_cookies VALUES
        ('WorkosCursorSessionToken', 'valid', '.cursor.com'),
        ('WorkosCursorSessionToken', 'malicious', 'evilcursor.com'),
        ('unrelated', 'private', '.cursor.com');
      """
    )
    sqlite3_close(db)
    db = nil

    let cookies = try #require(
      CursorBrowserCookieStore.queryFirefoxCookies(database: database)
    )
    #expect(cookies.count == 1)
    #expect(cookies.first?.name == "WorkosCursorSessionToken")
    #expect(cookies.first?.value == "valid")
  }

  private func execute(_ db: OpaquePointer?, _ sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    defer { sqlite3_free(errorMessage) }
    let status = sqlite3_exec(db, sql, nil, nil, &errorMessage)
    guard status == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? "SQLite error \(status)"
      throw ProviderFailure.unavailable(message)
    }
  }
}
