// folio-dev: desktop helper for working on Folio without a Mac.
//
//   folio-dev render --out preview/ [--theme midnight] [--layout paged] [--server URL --user NAME]
//       Syncs (demo account by default) and writes each article as a reader
//       page with the reader script inlined, plus a simulated read-along
//       player, so the page can be checked in any browser.
//   folio-dev sync --server URL --user NAME
//       Syncs a real server into a throwaway store and prints what arrived.
//       The API password is read from the FOLIO_PASSWORD environment variable.
//   folio-dev voice-server --server URL [--voice af_heart] [--text "…"]
//       Lists a speech server's voices and reads one sentence through the
//       same client the app uses, printing which words got timings.
//       An API key, if needed, comes from FOLIO_VOICE_KEY.
//   folio-dev fulltext URL… | --file LINKS
//       Fetches pages and extracts the article like the app's full-text
//       fetch, printing words found and the opening. LINKS lines may be
//       "name | summary length | url".

import Foundation
import FolioCore
import FolioFreshRSS
import FolioReader
import FolioAudio
import FolioStorage
import FolioSync

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("folio-dev: \(message)\n".utf8))
    exit(1)
}

func makeClient() throws -> GoogleReaderClient {
    if let server = argument("--server") {
        guard let user = argument("--user") else { fail("--user is required with --server") }
        guard let password = ProcessInfo.processInfo.environment["FOLIO_PASSWORD"] else {
            fail("set FOLIO_PASSWORD to the FreshRSS API password")
        }
        return GoogleReaderClient(endpoint: try ServerEndpoint(userInput: server),
                                  credentials: Credentials(username: user, apiPassword: password))
    }
    return GoogleReaderClient(endpoint: InMemoryReaderServer.demoEndpoint,
                              credentials: Credentials(username: InMemoryReaderServer.demoUsername,
                                                       apiPassword: InMemoryReaderServer.demoPassword),
                              transport: InMemoryReaderServer())
}

func escapeHTML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

/// Word ranges a speech engine would report, from the simulated engine.
@MainActor
func timeline(for script: SpeechScript) -> [[String]] {
    let engine = SimulatedSpeechEngine()
    var entries: [[String]] = []
    let observation = engine.addObserver { event in
        if case .range(let range) = event {
            entries.append([range.blockID, String(range.displayRange.lowerBound), String(range.displayRange.upperBound)])
        }
    }
    engine.speak(script, from: nil)
    while engine.step() {}
    observation.cancel()
    return entries
}

let demoPlayer = #"""
(() => {
  const data = JSON.parse(document.getElementById('folio-demo-timeline').textContent);
  const bar = document.createElement('div');
  bar.id = 'folio-demo-bar';
  bar.innerHTML = '<button id="folio-demo-play" type="button">▶ Read along</button><span id="folio-demo-note">simulated timing</span>';
  document.body.appendChild(bar);
  const style = document.createElement('style');
  style.nonce = document.currentScript.nonce;
  style.textContent = '#folio-demo-bar{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);display:flex;gap:10px;align-items:center;' +
    'padding:10px 14px;border-radius:999px;background:var(--fg);color:var(--bg);font:600 14px ui-sans-serif,-apple-system,sans-serif;' +
    'box-shadow:0 8px 30px rgba(0,0,0,.25);z-index:10;white-space:nowrap}#folio-demo-bar button{all:unset;cursor:pointer}' +
    '#folio-demo-note{opacity:.6;font-weight:500}';
  document.head.appendChild(style);
  let i = 0, timer = null;
  const button = document.getElementById('folio-demo-play');
  function stop() { clearInterval(timer); timer = null; button.textContent = '▶ Read along'; }
  button.addEventListener('click', (e) => {
    e.stopPropagation();
    if (timer) { stop(); return; }
    if (i >= data.length) i = 0;
    button.textContent = '❚❚ Pause';
    timer = setInterval(() => {
      if (i >= data.length) { stop(); window.folio.clearHighlight(); return; }
      const [block, start, end] = data[i++];
      window.folio.highlight(block, +start, +end, true);
    }, 230);
  });
  window.folioDemo = { data, seek: (n) => { i = n; } };
})();
"""#

@MainActor
func render() async throws {
    guard let out = argument("--out") else { fail("--out DIR is required") }
    let outURL = URL(fileURLWithPath: out, isDirectory: true)
    try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

    var settings = ReaderSettings()
    if let id = argument("--theme") {
        guard let theme = ReadingTheme.builtIn.first(where: { $0.id == id }) else { fail("unknown theme \(id)") }
        settings.theme = theme
    }
    settings.automaticThemes = nil
    if argument("--layout") == "paged" { settings.layout = .paginated }
    if let size = argument("--font-size").flatMap(Double.init) { settings.typography.fontSize = size }

    let store = try ArticleStore.inMemory()
    _ = try await SyncEngine(service: try makeClient(), store: store).sync()
    let feeds = Dictionary(uniqueKeysWithValues: try await store.feeds().map { ($0.id, $0.title) })
    let summaries = try await store.summaries(ArticleQuery(limit: 200))
    let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let renderer = ReaderHTMLRenderer(settings: settings, scriptMode: .inlineForPreview(nonce: nonce))
    let formatter = DateFormatter()
    formatter.dateStyle = .medium

    var index = "<!doctype html><meta charset=utf-8><title>Folio preview</title>"
        + "<body style=\"font:16px/1.5 system-ui;max-width:40em;margin:3em auto;padding:0 1em\"><h1>Folio preview</h1><ul>"
    for summary in summaries {
        guard let stored = try await store.article(summary.id) else { continue }
        let a = stored.article
        let document = ArticleParser.parse(html: a.contentHTML, baseURL: a.url, title: a.title)
        let meta = ReaderPageMetadata(
            title: a.title, siteName: feeds[a.feedID] ?? "", author: a.author, dateText: formatter.string(from: a.publishedAt),
            readingTimeText: "\(max(1, document.wordCount / 230)) min read", originalURL: a.url)
        var html = renderer.render(document, metadata: meta)
        let script = SpeechScript.build(document: document, title: a.title, articleID: a.id)
        let json = String(decoding: try JSONEncoder().encode(timeline(for: script)), as: UTF8.self)
        let extra = "<script type=\"application/json\" id=\"folio-demo-timeline\">\(json)</script>"
            + "<script nonce=\"\(nonce)\">\(demoPlayer)</script>"
        html = html.replacingOccurrences(of: "</body>", with: extra + "</body>")
        let file = "\(a.id.rawValue).html"
        try html.write(to: outURL.appendingPathComponent(file), atomically: true, encoding: .utf8)
        index += "<li><a href=\"\(file)\">\(escapeHTML(a.title))</a> — \(escapeHTML(feeds[a.feedID] ?? "")) "
            + "<small>(\(document.language?.rawValue ?? "?"), \(document.blocks.count) blocks, \(script.segments.count) segments)</small></li>"
    }
    index += "</ul></body>"
    try index.write(to: outURL.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    print("wrote \(summaries.count) articles to \(outURL.path)")
}

func sync() async throws {
    let store = try ArticleStore.inMemory()
    let started = Date()
    let report = try await SyncEngine(service: try makeClient(), store: store, progress: { phase in
        print("  \(phase)")
    }).sync()
    let stats = try await store.stats()
    print("synced in \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(report.feeds) feeds, "
          + "\(stats.articles) articles (\(stats.unread) unread, \(stats.starred) starred)")
    for summary in try await store.summaries(ArticleQuery(filter: .unread, limit: 5)) {
        print("  - \(summary.feedTitle): \(summary.title) [\(summary.estimatedReadingMinutes) min]")
    }
}

func voiceServer() async throws {
    guard let address = argument("--server"), let base = VoiceServer.normalizedBase(address) else {
        fail("voice-server needs --server URL")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("folio-dev-voice-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let synthesizer = RemoteSpeechSynthesizer(base: base, apiKey: ProcessInfo.processInfo.environment["FOLIO_VOICE_KEY"],
                                              cache: SpeechAudioCache(directory: directory.appendingPathComponent("cache")),
                                              scratch: directory.appendingPathComponent("scratch"))
    let ids = try await synthesizer.voices()
    print("\(base.absoluteString): \(ids.count) voices, e.g. \(ids.prefix(8).joined(separator: ", "))")
    let voice = argument("--voice") ?? ids.first { $0 == "af_heart" } ?? ids[0]
    let text = argument("--text") ?? "In 2026, Doctor Smith's team tested three new batteries. Each one lasted twice as long."
    let started = Date()
    let speech = try await synthesizer.synthesize(text: text, language: nil, voiceID: VoiceServer.prefix + voice)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: speech.audio.path)[.size] as? Int) ?? 0
    print("\(voice): \(bytes) bytes of audio in \(String(format: "%.1f", Date().timeIntervalSince(started))) s, about \(String(format: "%.1f", speech.duration)) s long")
    let utf16 = Array(text.utf16)
    let words = speech.words ?? []
    print("word timings: \(words.count) of \(text.split(separator: " ").count) words")
    for word in words {
        print(String(format: "  %6.2f–%6.2f  ", word.start, word.end) + String(decoding: utf16[word.range], as: UTF16.self))
    }
}

/// folio-dev clusters --file ITEMS.tsv [--threshold 0.30]
/// ITEMS.tsv: id, feed id, feed name, unix time, title, content (tab-separated).
func clusters() throws {
    guard let file = argument("--file") else { fail("clusters needs --file ITEMS.tsv") }
    let threshold = argument("--threshold").flatMap(Double.init)
    var items: [StoryClusters.Item] = []
    var names: [ArticleID: (feed: String, title: String)] = [:]
    for line in try String(contentsOfFile: file, encoding: .utf8).split(whereSeparator: \.isNewline) {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 5, let time = Double(fields[3]) else { continue }
        let id = ArticleID(fields[0])
        let title = HTMLText.decodeEntities(fields[4])
        let excerpt = fields.count > 5 ? HTMLText.decodeEntities(fields[5].replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)) : ""
        items.append(StoryClusters.Item(id: id, feedID: FeedID(fields[1]), title: title, excerpt: excerpt,
                                        publishedAt: Date(timeIntervalSince1970: time)))
        names[id] = (HTMLText.decodeEntities(fields[2]), title)
    }
    let started = Date()
    let groups = threshold.map { StoryClusters.find(items, threshold: $0) } ?? StoryClusters.find(items)
    print("\(items.count) articles, \(groups.count) stories with several sources (\(groups.reduce(0) { $0 + $1.count }) articles), in \(String(format: "%.2f", Date().timeIntervalSince(started))) s\n")
    for group in groups {
        for (index, id) in group.enumerated() {
            let entry = names[id]!
            print("\(index == 0 ? "●" : "  ") \(entry.feed.prefix(24).padding(toLength: 24, withPad: " ", startingAt: 0))  \(entry.title.prefix(90))")
        }
        print("")
    }
}

func fullText() async throws {
    if let path = argument("--local"), let address = argument("--url"), let url = URL(string: address) {
        let html = try String(contentsOfFile: path, encoding: .utf8)
        for line in FullTextExtractor.diagnose(html: html) { print(line) }
        guard let result = FullTextExtractor.extract(html: html, url: url) else { fail("no article found in \(path)") }
        let document = ArticleParser.parse(html: result.html, baseURL: url, title: nil)
        print("\(document.wordCount) words via \(result.source.rawValue)")
        for block in document.blocks.prefix(12) { print("  [\(block.kind)] \(block.text.prefix(100))") }
        return
    }
    var rows: [(name: String, summary: Int?, url: String)] = []
    if let file = argument("--file") {
        for line in try String(contentsOfFile: file, encoding: .utf8).split(whereSeparator: \.isNewline) {
            let parts = line.components(separatedBy: " | ")
            if parts.count >= 3 { rows.append((parts[0], Int(parts[1]), parts[2])) } else { rows.append(("", nil, String(line))) }
        }
    } else {
        rows = CommandLine.arguments.dropFirst(2).map { ("", nil, $0) }
    }
    let fetcher = FullTextFetcher()
    var found = 0
    for row in rows {
        let address = row.url.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "&amp;", with: "&")
        guard let url = URL(string: address) else { continue }
        let label = (row.name.isEmpty ? (url.host ?? address) : row.name).padding(toLength: 34, withPad: " ", startingAt: 0)
        guard FullTextFetcher.isSupported(url) else {
            print("\(label)  skipped (video, social or redirect link)")
            continue
        }
        let started = Date()
        do {
            if let result = try await fetcher.fetch(url) {
                let document = ArticleParser.parse(html: result.html, baseURL: url, title: nil)
                let opening = document.blocks.first { $0.text.count > 40 }?.text.prefix(70) ?? ""
                let summary = row.summary.map { " (feed: \($0) chars)" } ?? ""
                print("\(label)  \(String(format: "%5d", document.wordCount)) words via \(result.source.rawValue)\(summary), \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(opening)…")
                if document.wordCount >= 150 { found += 1 }
                if CommandLine.arguments.contains("--points") {
                    print("      → " + KeyPoints.headline(document: document, title: nil, language: document.language))
                }
            } else {
                print("\(label)  no article found (blocked, paywalled or not an article page)")
            }
        } catch {
            print("\(label)  failed: \(error.localizedDescription)")
        }
    }
    print("")
    print("full articles (150+ words): \(found) of \(rows.count)")
}

do {
    switch CommandLine.arguments.dropFirst().first {
    case "render": try await render()
    case "sync": try await sync()
    case "voice-server": try await voiceServer()
    case "fulltext": try await fullText()
    case "clusters": try clusters()
    default:
        print("usage: folio-dev render --out DIR [--theme ID] [--layout paged] | sync --server URL --user NAME | voice-server --server URL")
    }
} catch {
    fail(String(describing: error))
}
