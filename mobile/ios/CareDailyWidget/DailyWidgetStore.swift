import Foundation
import CryptoKit
import Security

// Only the app and its widget extension share this projection key. The main
// app's original default keychain group remains first and is never reused here.
enum DailyWidgetStore {
  static var group: String { Bundle.main.object(forInfoDictionaryKey: "CareWidgetAppGroup") as? String ?? "group.org.carenotebook.careNotebook.widget" }
  static var keyGroup: String? { Bundle.main.object(forInfoDictionaryKey: "CareWidgetKeychainGroup") as? String }
  static var directory: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
  static var available: Bool { directory != nil && keyGroup != nil }
  private static var file: URL? { directory?.appendingPathComponent("daily-widget.enc") }
  private static var query: [String: Any] {
    var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "care.daily-widget", kSecAttrAccount as String: "projection-v1"]
    if let keyGroup = keyGroup { value[kSecAttrAccessGroup as String] = keyGroup }
    return value
  }
  private static func key(create: Bool) throws -> SymmetricKey {
    var lookup = query
    lookup[kSecReturnData as String] = true
    var result: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data { return SymmetricKey(data: data) }
    guard status == errSecItemNotFound && create else { throw NSError(domain: "CareWidget", code: Int(status)) }
    var bytes = Data(count: 32)
    let randomStatus = bytes.withUnsafeMutableBytes { buffer in SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!) }
    guard randomStatus == errSecSuccess else { throw NSError(domain: "CareWidget", code: Int(randomStatus)) }
    var insert = query
    insert[kSecValueData as String] = bytes
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let added = SecItemAdd(insert as CFDictionary, nil)
    guard added == errSecSuccess else { throw NSError(domain: "CareWidget", code: Int(added)) }
    return SymmetricKey(data: bytes)
  }
  static func write(_ snapshot: [String: Any]?) throws {
    guard let file = file else { throw NSError(domain: "CareWidget", code: 1) }
    guard let snapshot = snapshot else {
      if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: "CareWidget", code: Int(status)) }
      return
    }
    let plain = try JSONSerialization.data(withJSONObject: snapshot)
    guard (snapshot["version"] as? Int) == 1 && plain.count <= 65536 else { throw NSError(domain: "CareWidget", code: 2) }
    let sealed = try AES.GCM.seal(plain, using: key(create: true)).combined!
    try sealed.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
    var url = file
    var values = URLResourceValues(); values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }
  static func read() -> [String: Any]? {
    do {
      guard let file = file,
            let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            (29...65600).contains(bytes) else { return nil }
      let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: file))
      let plain = try AES.GCM.open(sealed, using: key(create: false))
      guard let snapshot = try JSONSerialization.jsonObject(with: plain) as? [String: Any], (snapshot["version"] as? Int) == 1 else { return nil }
      return snapshot
    } catch { return nil }
  }
}
