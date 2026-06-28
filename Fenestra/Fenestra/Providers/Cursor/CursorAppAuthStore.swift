import Foundation
import SQLite3

enum CursorAppAuthStore {
  static func load() -> CursorAuthSession? {
    let database = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    guard FileManager.default.fileExists(atPath: database.path),
      let token = sqliteValue(database: database, key: "cursorAuth/accessToken"),
      let payload = jwtPayload(token),
      let subject = payload["sub"] as? String,
      let userID = subject.split(separator: "|").last.map(String.init),
      let expiry = ProviderDateParser.date(from: payload["exp"]),
      expiry.timeIntervalSinceNow > 60
    else {
      return nil
    }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    guard userID.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
    return CursorAuthSession(
      cookieHeader: "WorkosCursorSessionToken=\(userID)%3A%3A\(token)",
      source: "Cursor app session",
      userID: userID
    )
  }

  private static func sqliteValue(database: URL, key: String) -> String? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      sqlite3_close(db)
      return nil
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 250)

    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        db,
        "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      return nil
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    if sqlite3_column_type(statement, 0) == SQLITE_TEXT,
      let value = sqlite3_column_text(statement, 0)
    {
      return String(cString: value)
    }
    guard sqlite3_column_type(statement, 0) == SQLITE_BLOB,
      let bytes = sqlite3_column_blob(statement, 0)
    else {
      return nil
    }
    let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    return String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .utf16LittleEndian)
  }

  private static func jwtPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count > 1 else { return nil }
    var value = String(parts[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    value += String(repeating: "=", count: (4 - value.count % 4) % 4)
    guard let data = Data(base64Encoded: value) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
