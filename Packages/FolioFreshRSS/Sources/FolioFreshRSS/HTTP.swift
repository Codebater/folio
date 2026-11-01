import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable, Hashable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }

    public var method: Method
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: Method = .get, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// The only way the client talks to the network, so tests and the demo
/// account can swap in an in-memory server.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Network failures below HTTP (DNS, TLS, offline, timeouts).
public struct TransportError: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Kind: Sendable, Hashable { case offline, timedOut, cannotConnect, tls, cancelled, other }
    public var kind: Kind
    public var message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { "\(kind): \(message)" }
}

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "Folio/0.1 (+https://github.com/Codebater/folio)"]
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = request.body

        // The completion-handler API exists on every Foundation (Apple,
        // Linux, Windows); the async variant does not.
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: urlRequest) { data, response, error in
                if let error {
                    continuation.resume(throwing: Self.classify(error))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: TransportError(kind: .other, message: "Not an HTTP response"))
                    return
                }
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    headers[String(describing: key).lowercased()] = String(describing: value)
                }
                continuation.resume(returning: HTTPResponse(status: http.statusCode, headers: headers, body: data ?? Data()))
            }
            task.resume()
        }
    }

    static func classify(_ error: Error) -> TransportError {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return TransportError(kind: .other, message: nsError.localizedDescription)
        }
        let kind: TransportError.Kind
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff:
            kind = .offline
        case NSURLErrorTimedOut: kind = .timedOut
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed: kind = .cannotConnect
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorServerCertificateHasUnknownRoot:
            kind = .tls
        case NSURLErrorCancelled: kind = .cancelled
        default: kind = .other
        }
        return TransportError(kind: kind, message: nsError.localizedDescription)
    }
}

/// `application/x-www-form-urlencoded` with repeated keys, as the Google
/// Reader API expects (`i=1&i=2&a=...`).
public struct FormBody: Sendable {
    public private(set) var pairs: [(String, String)] = []

    public init(_ pairs: [(String, String)] = []) { self.pairs = pairs }

    public mutating func append(_ name: String, _ value: String) { pairs.append((name, value)) }

    public var encoded: Data {
        Data(pairs.map { "\(Self.escape($0.0))=\(Self.escape($0.1))" }.joined(separator: "&").utf8)
    }

    static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Parses a form body (used by the in-memory server).
    public static func decode(_ data: Data?) -> [(String, String)] {
        guard let data, !data.isEmpty else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[0])
            let value = parts.count > 1
                ? (String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[1])) : ""
            return (name, value)
        }
    }
}
