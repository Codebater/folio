import XCTest
@testable import Folio
import FolioCore
import FolioReader

@MainActor
final class FolioAppTests: XCTestCase {
    func testImageSchemeURLRoundTrips() {
        let original = URL(string: "https://cdn.example/a b/photo.jpg?w=1200&h=600")!
        let scheme = URL(string: ImageCache.schemeURL(for: original))!
        XCTAssertEqual(scheme.scheme, FolioImageSchemeHandler.scheme)
        XCTAssertEqual(ImageCache.originalURL(from: scheme), original)
    }

    func testSniffsImageTypes() {
        XCTAssertEqual(ImageCache.sniffMimeType(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])), "image/png")
        XCTAssertEqual(ImageCache.sniffMimeType(Data([0xFF, 0xD8, 0xFF, 0xE0])), "image/jpeg")
        XCTAssertEqual(ImageCache.sniffMimeType(Data("<svg xmlns='x'/>".utf8)), "image/svg+xml")
        XCTAssertEqual(ImageCache.sniffMimeType(Data("<html>".utf8)), "application/octet-stream")
    }

    func testListenPreferencesSurviveEncoding() throws {
        var preferences = ListenPreferences()
        preferences.rate = 1.5
        preferences.voiceByLanguage = ["de": "com.apple.voice.premium.de-DE.Anna"]
        let decoded = try JSONDecoder().decode(ListenPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded, preferences)
    }

    func testFreeUsersGetFreeReaderSettings() {
        var settings = ReaderSettings()
        settings.typography.font = .iowan
        XCTAssertFalse(settings.requiresPremium)  // typefaces are free
        settings.typography.letterSpacing = 0.03
        XCTAssertTrue(settings.requiresPremium)
        XCTAssertFalse(settings.restrictedToFree().requiresPremium)
    }

    func testThemeColorsConvert() {
        let (r, g, b) = ThemeColor("#9C4A1A").rgb
        XCTAssertEqual(r, 0x9C / 255, accuracy: 0.001)
        XCTAssertEqual(g, 0x4A / 255, accuracy: 0.001)
        XCTAssertEqual(b, 0x1A / 255, accuracy: 0.001)
    }
}
