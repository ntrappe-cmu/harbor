import Foundation
import Security

public protocol CredentialStore: Sendable {
    func load(_ assistant: Assistant) throws -> String?
    func save(_ key: String, for assistant: Assistant) throws
    func remove(_ assistant: Assistant) throws
}
public enum CredentialValidation {
    public static func normalized(_ input: String) throws -> String {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw WorkspaceError.invalid("Paste an API key before saving.") }
        guard key.utf8.count <= 4096,
              !key.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw WorkspaceError.invalid("Use a single API key with no spaces or line breaks.")
        }
        return key
    }
}
public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public init(service: String = "dev.harbor.workspace.api-keys") { self.service = service }
    private func query(_ assistant: Assistant) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: assistant == .codex ? "codex" : "claude",
         kSecAttrSynchronizable as String: false]
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            // System messages never include the key or keychain result data.
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
            throw WorkspaceError.invalid("macOS Keychain couldn’t complete the request. \(message) Try again after unlocking your login keychain.")
        }
    }
    public func load(_ assistant: Assistant) throws -> String? {
        var request = query(assistant)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.invalid("The saved API key couldn’t be read. Replace it in Harbor’s assistant settings.")
        }
        return try CredentialValidation.normalized(key)
    }
    public func save(_ input: String, for assistant: Assistant) throws {
        let key = try CredentialValidation.normalized(input)
        let match = query(assistant)
        let data = Data(key.utf8)
        let status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = match
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Harbor — \(assistant.rawValue) API key"
            item[kSecAttrDescription as String] = "API credential used by Harbor workspaces on this Mac"
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }
    public func remove(_ assistant: Assistant) throws {
        let status = SecItemDelete(query(assistant) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}
