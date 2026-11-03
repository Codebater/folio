import Foundation
import FolioFreshRSS

/// Small typed wrapper over UserDefaults for settings that are not secret.
/// Passwords never go here; they live in the Keychain.
enum Preferences {
    enum Key: String, CaseIterable {
        case account = "folio.account"
        case readerSettings = "folio.readerSettings"
        case listenPreferences = "folio.listenPreferences"
        case lastSyncedAt = "folio.lastSyncedAt"
        case listening = "folio.listening"
        case readingList = "folio.readingList"
        case listMarkers = "folio.listMarkers"
    }

    static func removeAll() {
        for key in Key.allCases { remove(key) }
    }

    static func load<T: Decodable>(_ key: Key, as type: T.Type = T.self) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key.rawValue) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, key: Key) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key.rawValue)
    }

    static func remove(_ key: Key) {
        UserDefaults.standard.removeObject(forKey: key.rawValue)
    }
}

/// Which account the app is connected to.
enum StoredAccount: Codable, Equatable {
    case demo
    case server(AccountConfiguration)
    /// A reading list on this iPhone: Paperwire fetches the feeds itself.
    case local
}
