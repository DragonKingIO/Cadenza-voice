import Foundation
import CryptoKit
import Security

// Per-device credentials for the local interface. A device is a named, revocable token with its own permissions.
// Only a SHA-256 hash of the token is stored; the token itself is shown once, when the device is created.

enum LocalAPIPermission: String, CaseIterable, Codable, Hashable {
    case mic     // start, stop and cancel recordings with the Mac's microphone
    case audio   // submit audio and receive text
    case insert  // ask the app to type the final text into the front app (also needs the global switch)

    var titleKey: String { "developer.perm." + rawValue }
}

struct LocalAPIPrincipal: Equatable {
    let id: String          // "owner" or the device id
    let name: String
    let permissions: Set<LocalAPIPermission>
    var isOwner: Bool { id == "owner" }
    func allows(_ p: LocalAPIPermission) -> Bool { permissions.contains(p) }
    /// The owner token (the one in Settings) can record and submit audio, but never type into other apps.
    static let owner = LocalAPIPrincipal(id: "owner", name: "owner", permissions: [.mic, .audio])
}

protocol LocalAPIAuthority {
    func principal(authorization: String?) -> LocalAPIPrincipal?
}

struct LocalAPIDevice: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var permissions: [String]
    var tokenHash: String
    var created: Date
    var permissionSet: Set<LocalAPIPermission> { Set(permissions.compactMap(LocalAPIPermission.init(rawValue:))) }
}

enum LocalAPIDeviceError: Error, Equatable { case invalidName, noPermissions, tooMany, saveFailed }

final class LocalAPIDeviceStore {
    static let maxDevices = 16
    static let maxNameLength = 40
    private let url: URL
    private(set) var devices: [LocalAPIDevice] = []

    init(directory: URL) {
        url = directory.appendingPathComponent("local-api-devices.json")
        load()
    }
    static let standard = LocalAPIDeviceStore(directory: AppPaths.supportDir)

    private func load() {
        guard let data = try? Data(contentsOf: url) else { devices = []; return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        devices = ((try? decoder.decode([LocalAPIDevice].self, from: data)) ?? []).prefix(Self.maxDevices).map { $0 }
    }

    private func save() -> Bool {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(devices) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let body = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "cdz_" + body
    }

    /// Returns the new device and its token. The token cannot be recovered later.
    func add(name: String, permissions: Set<LocalAPIPermission>) -> Result<(device: LocalAPIDevice, token: String), LocalAPIDeviceError> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maxNameLength, !trimmed.contains(where: { $0.isNewline || $0.unicodeScalars.contains { $0.value < 32 } }) else { return .failure(.invalidName) }
        guard !permissions.isEmpty else { return .failure(.noPermissions) }
        guard devices.count < Self.maxDevices else { return .failure(.tooMany) }
        let token = Self.randomToken()
        var idBytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, idBytes.count, &idBytes)
        let device = LocalAPIDevice(id: idBytes.map { String(format: "%02x", $0) }.joined(), name: trimmed,
                                    permissions: permissions.map(\.rawValue).sorted(), tokenHash: Self.hash(token), created: Date())
        devices.append(device)
        guard save() else { devices.removeLast(); return .failure(.saveFailed) }
        return .success((device, token))
    }

    @discardableResult func revoke(id: String) -> Bool {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return false }
        let removed = devices.remove(at: index)
        if !save() { devices.insert(removed, at: index); return false }
        return true
    }

    /// Looks the token up by hash, comparing every stored hash in constant time.
    func device(forToken token: String) -> LocalAPIDevice? {
        let presented = Array(Self.hash(token).utf8)
        var match: LocalAPIDevice?
        for device in devices {
            let stored = Array(device.tokenHash.utf8)
            var diff = stored.count ^ presented.count
            for i in 0..<min(stored.count, presented.count) { diff |= Int(stored[i] ^ presented[i]) }
            if diff == 0 { match = device }
        }
        return match
    }
}

/// Owner token first, then device tokens. A revoke removes the device from the live list, so it stops working at once.
struct LocalAPITokenAuthority: LocalAPIAuthority {
    let ownerToken: () -> String
    let devices: LocalAPIDeviceStore

    func principal(authorization: String?) -> LocalAPIPrincipal? {
        if LocalAPIAuth.verify(header: authorization, token: ownerToken()) { return .owner }
        guard let header = authorization, header.count > 7, header.prefix(7).lowercased() == "bearer " else { return nil }
        let token = header.dropFirst(7).trimmingCharacters(in: .whitespaces)
        guard let device = devices.device(forToken: token) else { return nil }
        return LocalAPIPrincipal(id: device.id, name: device.name, permissions: device.permissionSet)
    }
}

/// Only the owner token (tests and simple setups).
struct LocalAPIOwnerAuthority: LocalAPIAuthority {
    let token: () -> String
    func principal(authorization: String?) -> LocalAPIPrincipal? { LocalAPIAuth.verify(header: authorization, token: token()) ? .owner : nil }
}
