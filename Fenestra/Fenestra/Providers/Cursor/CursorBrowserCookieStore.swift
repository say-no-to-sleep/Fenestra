import CommonCrypto
import CryptoKit
import Foundation
import SQLite3

@MainActor
enum CursorBrowserCookieStore {
  private(set) static var keychainApprovalRequired = false

  private static let sessionNames: Set<String> = [
    "WorkosCursorSessionToken",
    "__Secure-next-auth.session-token",
    "next-auth.session-token",
    "wos-session",
    "__Secure-wos-session",
    "authjs.session-token",
    "__Secure-authjs.session-token",
  ]

  static func load(
    allowKeychainAccess: Bool,
    allowInteraction: Bool = false
  ) -> CursorAuthSession? {
    keychainApprovalRequired = false
    if let firefox = loadFirefox() {
      return firefox
    }
    if let safari = loadSafari() {
      return safari
    }
    guard allowKeychainAccess else { return nil }
    if let chrome = loadChromium(
      applicationSupportName: "Google/Chrome",
      keychainService: "Chrome Safe Storage",
      source: "Chrome cookies",
      allowInteraction: allowInteraction
    ) {
      return chrome
    }
    return loadChromium(
      applicationSupportName: "Microsoft Edge",
      keychainService: "Microsoft Edge Safe Storage",
      source: "Edge cookies",
      allowInteraction: allowInteraction
    )
  }

  static func resetKeychainCache() {
    KeychainReader.invalidate(service: "Chrome Safe Storage")
    KeychainReader.invalidate(service: "Microsoft Edge Safe Storage")
  }

  static var keychainBrowserDetected: Bool {
    let support = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support")
    return FileManager.default.fileExists(atPath: support.appending(path: "Google/Chrome").path)
      || FileManager.default.fileExists(
        atPath: support.appending(path: "Microsoft Edge").path
      )
  }

  private static func loadFirefox() -> CursorAuthSession? {
    let profiles = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support/Firefox/Profiles")
    guard
      let children = try? FileManager.default.contentsOfDirectory(
        at: profiles,
        includingPropertiesForKeys: nil
      )
    else {
      return nil
    }
    for profile in children {
      let database = profile.appending(path: "cookies.sqlite")
      if let cookies = queryFirefoxCookies(database: database),
        let session = makeSession(cookies: cookies, source: "Firefox cookies")
      {
        return session
      }
    }
    return nil
  }

  private static func loadChromium(
    applicationSupportName: String,
    keychainService: String,
    source: String,
    allowInteraction: Bool
  ) -> CursorAuthSession? {
    let root = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support")
      .appending(path: applicationSupportName)
    guard FileManager.default.fileExists(atPath: root.path) else { return nil }
    let passwordData: Data
    do {
      guard
        let value = try KeychainReader.genericPassword(
          service: keychainService,
          allowInteraction: allowInteraction
        )
      else {
        keychainApprovalRequired = !allowInteraction
        return nil
      }
      passwordData = value
    } catch {
      keychainApprovalRequired = true
      return nil
    }
    guard
      let password = String(data: passwordData, encoding: .utf8),
      let key = chromiumKey(password: password),
      let profiles = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey]
      )
    else {
      return nil
    }
    let ordered = profiles.sorted {
      ($0.lastPathComponent == "Default" ? 0 : 1)
        < ($1.lastPathComponent == "Default" ? 0 : 1)
    }
    for profile in ordered {
      let candidates = [
        profile.appending(path: "Network/Cookies"),
        profile.appending(path: "Cookies"),
      ]
      for database in candidates {
        if let cookies = queryChromiumCookies(database: database, decryptionKey: key),
          let session = makeSession(cookies: cookies, source: source)
        {
          return session
        }
      }
    }
    return nil
  }

  private static func queryChromiumCookies(
    database: URL,
    decryptionKey: Data
  ) -> [(name: String, value: String)]? {
    withPrivateDatabaseCopy(of: database) { copy in
      var db: OpaquePointer?
      guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return nil
      }
      defer { sqlite3_close(db) }
      let sql = """
        SELECT name, value, encrypted_value, host_key
        FROM cookies
        WHERE host_key LIKE '%cursor.com' OR host_key LIKE '%cursor.sh';
        """
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        return nil
      }
      defer { sqlite3_finalize(statement) }

      var cookies: [(String, String)] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let nameValue = sqlite3_column_text(statement, 0) else { continue }
        let name = String(cString: nameValue)
        let host = sqlite3_column_text(statement, 3).map(String.init(cString:)) ?? ""
        guard sessionNames.contains(name), isCursorDomain(host) else { continue }

        var value = sqlite3_column_text(statement, 1).map(String.init(cString:)) ?? ""
        if value.isEmpty, let bytes = sqlite3_column_blob(statement, 2) {
          let encrypted = Data(
            bytes: bytes,
            count: Int(sqlite3_column_bytes(statement, 2))
          )
          value = decryptChromiumCookie(encrypted, key: decryptionKey, host: host) ?? ""
        }
        guard !value.isEmpty else { continue }
        cookies.append((name, value))
      }
      return cookies.isEmpty ? nil : cookies
    }
  }

  static func queryFirefoxCookies(
    database: URL
  ) -> [(name: String, value: String)]? {
    withPrivateDatabaseCopy(of: database) { copy in
      var db: OpaquePointer?
      guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return nil
      }
      defer { sqlite3_close(db) }
      let sql = """
        SELECT name, value, host
        FROM moz_cookies
        WHERE host LIKE '%cursor.com' OR host LIKE '%cursor.sh';
        """
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        return nil
      }
      defer { sqlite3_finalize(statement) }

      var cookies: [(String, String)] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let nameValue = sqlite3_column_text(statement, 0),
          let valueValue = sqlite3_column_text(statement, 1)
        else {
          continue
        }
        let name = String(cString: nameValue)
        let value = String(cString: valueValue)
        let host = sqlite3_column_text(statement, 2).map(String.init(cString:)) ?? ""
        guard sessionNames.contains(name), isCursorDomain(host), !value.isEmpty else {
          continue
        }
        cookies.append((name, value))
      }
      return cookies.isEmpty ? nil : cookies
    }
  }

  private static func withPrivateDatabaseCopy<T>(
    of database: URL,
    _ body: (URL) -> T?
  ) -> T? {
    guard FileManager.default.fileExists(atPath: database.path) else { return nil }
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "fenestra-cookies-\(UUID().uuidString)", directoryHint: .isDirectory)
    let copy = directory.appending(path: database.lastPathComponent)
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.copyItem(at: database, to: copy)
      for suffix in ["-wal", "-shm"] {
        let sidecar = URL(filePath: database.path + suffix)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
        try FileManager.default.copyItem(
          at: sidecar,
          to: URL(filePath: copy.path + suffix)
        )
      }
    } catch {
      try? FileManager.default.removeItem(at: directory)
      return nil
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    return body(copy)
  }

  private static func loadSafari() -> CursorAuthSession? {
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Cookies/Cookies.binarycookies")
    guard let data = try? Data(contentsOf: url),
      data.count >= 8,
      String(data: data.prefix(4), encoding: .ascii) == "cook"
    else {
      return nil
    }
    let pageCount = Int(bigEndianUInt32(data, at: 4) ?? 0)
    guard pageCount > 0, data.count >= 8 + pageCount * 4 else { return nil }
    var pageOffset = 8 + pageCount * 4
    var cookies: [(String, String)] = []
    for index in 0..<pageCount {
      let size = Int(bigEndianUInt32(data, at: 8 + index * 4) ?? 0)
      guard size > 0, pageOffset + size <= data.count else { break }
      let page = data.subdata(in: pageOffset..<(pageOffset + size))
      cookies.append(contentsOf: parseSafariPage(page))
      pageOffset += size
    }
    guard !cookies.isEmpty else { return nil }
    let known = cookies.filter { sessionNames.contains($0.0) }
    return makeSession(
      cookies: known.isEmpty ? cookies : known,
      source: "Safari cookies"
    )
  }

  private static func parseSafariPage(_ page: Data) -> [(String, String)] {
    guard page.count >= 8 else { return [] }
    let count = Int(littleEndianUInt32(page, at: 4) ?? 0)
    guard count > 0, page.count >= 8 + count * 4 else { return [] }
    var result: [(String, String)] = []
    for index in 0..<count {
      let offset = Int(littleEndianUInt32(page, at: 8 + index * 4) ?? 0)
      guard offset >= 0, offset + 40 <= page.count else { continue }
      let size = Int(littleEndianUInt32(page, at: offset) ?? 0)
      guard size >= 40, offset + size <= page.count else { continue }
      let urlOffset = Int(littleEndianUInt32(page, at: offset + 16) ?? 0)
      let nameOffset = Int(littleEndianUInt32(page, at: offset + 20) ?? 0)
      let valueOffset = Int(littleEndianUInt32(page, at: offset + 28) ?? 0)
      guard let domain = nullTerminatedString(page, at: offset + urlOffset),
        isCursorDomain(domain),
        let name = nullTerminatedString(page, at: offset + nameOffset),
        let value = nullTerminatedString(page, at: offset + valueOffset),
        sessionNames.contains(name),
        !name.isEmpty,
        !value.isEmpty
      else {
        continue
      }
      result.append((name, value))
    }
    return result
  }

  private static func chromiumKey(password: String) -> Data? {
    let passwordBytes = Array(password.utf8)
    let salt = Array("saltysalt".utf8)
    var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
    let result = CCKeyDerivationPBKDF(
      CCPBKDFAlgorithm(kCCPBKDF2),
      passwordBytes,
      passwordBytes.count,
      salt,
      salt.count,
      CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
      1003,
      &key,
      key.count
    )
    return result == kCCSuccess ? Data(key) : nil
  }

  private static func decryptChromiumCookie(
    _ encrypted: Data,
    key: Data,
    host: String
  ) -> String? {
    guard encrypted.count > 3 else { return nil }
    let prefix = String(data: encrypted.prefix(3), encoding: .ascii)
    guard prefix == "v10" || prefix == "v11" else {
      return String(data: encrypted, encoding: .utf8)
    }
    let ciphertext = encrypted.dropFirst(3)
    var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
    var moved = 0
    let status = key.withUnsafeBytes { keyBytes in
      ciphertext.withUnsafeBytes { encryptedBytes in
        CCCrypt(
          CCOperation(kCCDecrypt),
          CCAlgorithm(kCCAlgorithmAES),
          CCOptions(kCCOptionPKCS7Padding),
          keyBytes.baseAddress,
          key.count,
          Array(repeating: UInt8(0x20), count: kCCBlockSizeAES128),
          encryptedBytes.baseAddress,
          ciphertext.count,
          &output,
          output.count,
          &moved
        )
      }
    }
    guard status == kCCSuccess else { return nil }
    var plaintext = Data(output.prefix(moved))
    let expectedHostDigest = Data(SHA256.hash(data: Data(host.utf8)))
    if plaintext.count > expectedHostDigest.count,
      Data(plaintext.prefix(expectedHostDigest.count)) == expectedHostDigest
    {
      // Chrome 24+ authenticates the cookie's host before the encrypted value.
      plaintext.removeFirst(32)
    }
    return String(data: plaintext, encoding: .utf8)
  }

  private static func makeSession(
    cookies: [(String, String)],
    source: String
  ) -> CursorAuthSession? {
    var seenNames: Set<String> = []
    let header = cookies.compactMap { name, value -> String? in
      let forbiddenNameCharacters = CharacterSet(charactersIn: "=;\r\n\0")
      let forbiddenValueCharacters = CharacterSet(charactersIn: ";\r\n\0")
      guard !name.isEmpty,
        seenNames.insert(name).inserted,
        name.rangeOfCharacter(from: forbiddenNameCharacters) == nil,
        value.rangeOfCharacter(from: forbiddenValueCharacters) == nil
      else {
        return nil
      }
      return "\(name)=\(value)"
    }.joined(separator: "; ")
    guard !header.isEmpty else { return nil }
    return CursorAuthSession(cookieHeader: header, source: source, userID: nil)
  }

  nonisolated static func isCursorDomain(_ domain: String) -> Bool {
    let normalized =
      domain
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))
      .lowercased()
    return normalized == "cursor.com"
      || normalized.hasSuffix(".cursor.com")
      || normalized == "cursor.sh"
      || normalized.hasSuffix(".cursor.sh")
  }

  private static func bigEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }

  private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return data[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) {
      $0 | (UInt32($1.element) << UInt32($1.offset * 8))
    }
  }

  private static func nullTerminatedString(_ data: Data, at offset: Int) -> String? {
    guard offset >= 0, offset < data.count else { return nil }
    let tail = data[offset...]
    let end = tail.firstIndex(of: 0) ?? data.endIndex
    return String(data: data[offset..<end], encoding: .utf8)
  }
}
