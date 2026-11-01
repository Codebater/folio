import Foundation
import FolioCore

/// Where the Google Reader API of a FreshRSS server lives.
public struct ServerEndpoint: Hashable, Sendable, Codable {
    /// The API base, always ending in `greader.php`, e.g.
    /// `https://vault.tailnet.ts.net:8091/api/greader.php`.
    public let apiBase: URL

    public init(apiBase: URL) { self.apiBase = apiBase }

    /// Accepts what people type: a bare host, the FreshRSS root, or the full
    /// API URL. Plain `http://` is allowed (local mock server, LAN); the app
    /// warns about it.
    public init(userInput: String) throws(GoogleReaderError) {
        var text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .invalidServerURL(userInput) }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty
        else { throw .invalidServerURL(userInput) }
        components.query = nil
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/i") { path.removeLast(2) }  // FreshRSS web UI path
        if !path.hasSuffix("greader.php") { path += "/api/greader.php" }
        components.path = path
        guard let url = components.url else { throw .invalidServerURL(userInput) }
        apiBase = url
    }

    public var isSecure: Bool { apiBase.scheme?.lowercased() == "https" }

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)!
        // Stream ids contain "/" and ":" which must stay as path text but be
        // escaped where they would break the path (e.g. "?" or "#").
        components.percentEncodedPath = components.percentEncodedPath + "/" + path
        var items = query
        items.append(URLQueryItem(name: "output", value: "json"))
        components.queryItems = items
        // URLComponents leaves "+" alone in queries, but PHP reads it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}

public struct Credentials: Hashable, Sendable {
    public var username: String
    /// The FreshRSS *API password* (Settings → Profile), not the web login.
    public var apiPassword: String

    public init(username: String, apiPassword: String) {
        self.username = username
        self.apiPassword = apiPassword
    }
}

public enum GoogleReaderError: Error, Sendable, Hashable, RetryClassifiable, CustomStringConvertible {
    case invalidServerURL(String)
    /// Username or API password rejected at login.
    case invalidCredentials
    /// The session token stopped working and a fresh login also failed.
    case unauthorized
    /// 404 on the API path: wrong URL, or the API is disabled in FreshRSS.
    case apiNotFound
    case server(status: Int, message: String)
    case malformedResponse(String)
    case transport(TransportError)

    public var isTransient: Bool {
        switch self {
        case .server(let status, _): status >= 500 || status == 429 || status == 408
        case .transport(let error): error.kind != .cancelled && error.kind != .tls
        default: false
        }
    }

    public var isAuthenticationFailure: Bool {
        self == .invalidCredentials || self == .unauthorized
    }

    public var description: String {
        switch self {
        case .invalidServerURL(let s): "That doesn't look like a server address: \(s)"
        case .invalidCredentials: "The server rejected the username or API password."
        case .unauthorized: "The server ended the session. Sign in again."
        case .apiNotFound:
            "No Google Reader API at this address. Check the URL and enable API access in FreshRSS (Settings → Authentication)."
        case .server(let status, let message): "Server error \(status): \(message.prefix(200))"
        case .malformedResponse(let what): "Unexpected response from the server (\(what))."
        case .transport(let error): error.kind == .offline ? "You're offline." : "Couldn't reach the server: \(error.message)"
        }
    }
}

/// Google Reader stream ids.
public enum StreamID {
    public static let readingList = "user/-/state/com.google/reading-list"
    public static let read = "user/-/state/com.google/read"
    public static let starred = "user/-/state/com.google/starred"
    public static let kept = "user/-/state/com.google/kept-unread"

    public static func label(_ name: String) -> String { "user/-/label/\(name)" }
}

/// Conversions between the two Google Reader item id forms.
///
/// Long form: `tag:google.com,2005:reader/item/000000000000001f` (16 hex
/// digits). Short form: the same 64-bit number in decimal, `"31"`. FreshRSS
/// ids are microsecond timestamps, so they need all 64 bits.
public enum ItemID {
    static let longPrefix = "tag:google.com,2005:reader/item/"

    public static func shortForm(_ id: String) -> String? {
        if id.hasPrefix(longPrefix) {
            let hex = id.dropFirst(longPrefix.count)
            guard let value = UInt64(hex, radix: 16) else { return nil }
            return String(value)
        }
        guard !id.isEmpty, id.allSatisfy(\.isASCII), let value = UInt64(id) else { return nil }
        return String(value)
    }

    public static func longForm(_ shortID: String) -> String? {
        guard let value = UInt64(shortID) else { return nil }
        let hex = String(value, radix: 16)
        return longPrefix + String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}
