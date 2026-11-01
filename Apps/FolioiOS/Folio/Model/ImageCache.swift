import CryptoKit
import Foundation
import WebKit

/// Disk cache for article images, so downloaded articles show their
/// pictures offline. Files are keyed by the SHA-256 of the image URL and
/// live in Caches (iOS may purge them under storage pressure; the article
/// text stays in the database regardless).
actor ImageCache {
    nonisolated let directory: URL
    private let session: URLSession

    static let maximumImageBytes = 20 * 1024 * 1024

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["Accept": "image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8"]
        session = URLSession(configuration: configuration)
    }

    /// The custom-scheme URL the reader page uses for an image.
    static func schemeURL(for url: URL) -> String {
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return "\(FolioImageSchemeHandler.scheme)://image?u=\(encoded)"
    }

    static func originalURL(from schemeURL: URL) -> URL? {
        URLComponents(url: schemeURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "u" }?.value.flatMap(URL.init(string:))
    }

    nonisolated func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest)
    }

    /// Cached bytes, or downloads and caches them.
    func data(for url: URL) async throws -> (data: Data, mimeType: String) {
        let file = fileURL(for: url)
        if let data = try? Data(contentsOf: file) { return (data, Self.sniffMimeType(data)) }
        guard url.scheme == "https" || url.scheme == "http" else { throw URLError(.unsupportedURL) }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= Self.maximumImageBytes
        else { throw URLError(.badServerResponse) }
        let mime = Self.sniffMimeType(data)
        guard mime.hasPrefix("image/") else { throw URLError(.cannotDecodeContentData) }
        try? data.write(to: file, options: .atomic)
        return (data, mime)
    }

    func cachedData(for url: URL) -> Data? { try? Data(contentsOf: fileURL(for: url)) }

    /// Downloads images not yet cached; returns how many are now available.
    func prefetch(_ urls: [URL]) async -> Int {
        var available = 0
        for url in Set(urls) {
            if (try? await data(for: url)) != nil { available += 1 }
        }
        return available
    }

    func totalBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clear() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    static func sniffMimeType(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if bytes.count >= 12, bytes[0..<4].elementsEqual(Array("RIFF".utf8)), bytes[8..<12].elementsEqual(Array("WEBP".utf8)) {
            return "image/webp"
        }
        if bytes.count >= 12, bytes[4..<8].elementsEqual(Array("ftyp".utf8)) {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            return brand.hasPrefix("avi") ? "image/avif" : "image/heic"
        }
        let head = String(decoding: data.prefix(256), as: UTF8.self).lowercased()
        if head.contains("<svg") { return "image/svg+xml" }
        return "application/octet-stream"
    }
}

/// Serves `folio-image://image?u=<url>` to the reader web view from the
/// image cache. The page's CSP only allows this scheme and `data:`, so the
/// web view never contacts image hosts directly; offline, cached images still
/// load and uncached ones fail quietly.
@MainActor
final class FolioImageSchemeHandler: NSObject, @preconcurrency WKURLSchemeHandler {
    nonisolated static let scheme = "folio-image"

    private let cache: ImageCache
    private var active = Set<ObjectIdentifier>()

    init(cache: ImageCache) {
        self.cache = cache
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let requestURL = urlSchemeTask.request.url, let original = ImageCache.originalURL(from: requestURL) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        active.insert(id)
        let cache = self.cache
        Task { @MainActor in
            do {
                let (data, mime) = try await cache.data(for: original)
                guard self.active.remove(id) != nil else { return }
                urlSchemeTask.didReceive(URLResponse(url: requestURL, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                guard self.active.remove(id) != nil else { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        active.remove(ObjectIdentifier(urlSchemeTask))
    }
}
