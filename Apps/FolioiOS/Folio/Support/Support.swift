import SafariServices
import SwiftUI
import FolioCore
import FolioReader

extension Color {
    init(_ color: ThemeColor) {
        let (r, g, b) = color.rgb
        self.init(red: r, green: g, blue: b)
    }
}

enum Format {
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func readingTime(_ minutes: Int) -> String { "\(minutes) min read" }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// In-app browser for article links, so reading never leaves Folio.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Article image from the offline cache (downloading it if needed). SVG and
/// missing images fall back to generated artwork in the theme's palette, so
/// rows never show a broken image.
struct ArticleThumbnail: View {
    let url: URL?
    let fallbackText: String
    /// Shown instead of the initial when there is no image.
    var fallbackSymbol: String?
    @Environment(AppModel.self) private var model
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ThemeArtwork(key: fallbackText, symbol: fallbackSymbol, initial: fallbackSymbol == nil ? fallbackText : nil)
            }
        }
        .clipped()
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        if url.scheme == "data" {
            if let data = try? Data(contentsOf: url) { image = UIImage(data: data) }
            return
        }
        if let result = try? await model.imageCache.data(for: url) { image = UIImage(data: result.data) }
    }
}
