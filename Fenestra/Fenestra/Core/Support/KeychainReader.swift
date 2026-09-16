import Foundation
import LocalAuthentication
import Security

@MainActor
enum KeychainReader {
  private struct CacheKey: Hashable {
    let service: String
    let account: String?
  }

  private enum CacheEntry {
    case value(Data?)
    case failure(String)
  }

  private static var cache: [CacheKey: CacheEntry] = [:]

  static func genericPassword(
    service: String,
    account: String? = nil,
    allowInteraction: Bool = false
  ) throws -> Data? {
    let cacheKey = CacheKey(service: service, account: account)
    if let cached = cache[cacheKey] {
      switch cached {
      case .value(let data):
        return data
      case .failure(let message):
        throw ProviderFailure.unavailable(message)
      }
    }

    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: true,
    ]
    if allowInteraction {
      query[kSecUseAuthenticationContext as String] = LAContext()
    } else {
      query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
    }
    if let account {
      query[kSecAttrAccount as String] = account
    }

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      let data = result as? Data
      cache[cacheKey] = .value(data)
      return data
    case errSecItemNotFound:
      cache[cacheKey] = .value(nil)
      return nil
    case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
      let message =
        allowInteraction
        ? "Keychain access was not granted"
        : "Keychain access requires approval"
      cache[cacheKey] = .failure(message)
      throw ProviderFailure.unavailable(message)
    default:
      let message =
        "Keychain read failed "
        + "(\(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"))"
      cache[cacheKey] = .failure(message)
      throw ProviderFailure.unavailable(message)
    }
  }

  static func updateGenericPassword(
    service: String,
    account: String? = nil,
    data: Data
  ) throws {
    invalidate(service: service, account: account)
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ]
    if let account {
      query[kSecAttrAccount as String] = account
    }
    let status = SecItemUpdate(
      query as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    switch status {
    case errSecSuccess:
      cache[CacheKey(service: service, account: account)] = .value(data)
    case errSecItemNotFound:
      throw ProviderFailure.unavailable("Keychain item missing")
    case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
      throw ProviderFailure.unavailable("Keychain access requires approval")
    default:
      let message =
        "Keychain update failed "
        + "(\(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"))"
      throw ProviderFailure.unavailable(message)
    }
  }

  static func invalidate(service: String, account: String? = nil) {
    cache.removeValue(forKey: CacheKey(service: service, account: account))
  }
}
