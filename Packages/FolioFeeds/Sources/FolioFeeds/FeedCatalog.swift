import Foundation

/// A well-known feed someone new to RSS can add with one tap. Every address
/// here was fetched and parsed before it was listed (2026-11-03); the
/// descriptions are ours.
public struct CatalogFeed: Sendable, Hashable, Identifiable {
    public enum Topic: String, Sendable, CaseIterable, Identifiable {
        case news, technology, science, business, design, culture, sport

        public var id: String { rawValue }

        /// Also the category the feed is filed under, so topic stations work.
        public var label: String {
            switch self {
            case .news: "News"
            case .technology: "Technology"
            case .science: "Science"
            case .business: "Business"
            case .design: "Design"
            case .culture: "Culture"
            case .sport: "Sport"
            }
        }

        public var symbol: String {
            switch self {
            case .news: "globe.europe.africa"
            case .technology: "cpu"
            case .science: "atom"
            case .business: "chart.line.uptrend.xyaxis"
            case .design: "paintpalette"
            case .culture: "theatermasks"
            case .sport: "sportscourt"
            }
        }
    }

    public var title: String
    public var url: URL
    /// The site's address as people know it ("bbc.co.uk").
    public var site: String
    public var topic: Topic
    /// Base language code.
    public var language: String
    public var blurb: String

    public var id: String { url.absoluteString }
}

/// A few feeds that make a good start together.
public struct StarterPack: Sendable, Hashable, Identifiable {
    public var title: String
    public var subtitle: String
    public var symbol: String
    public var language: String
    public var feedURLs: [URL]

    public var id: String { language + ":" + title }
}

public enum FeedCatalog {
    public static let feeds: [CatalogFeed] = entries.map { entry in
        CatalogFeed(title: entry.1, url: URL(string: entry.2)!, site: entry.3, topic: entry.0, language: entry.4, blurb: entry.5)
    }

    public static func feed(_ url: URL) -> CatalogFeed? { feeds.first { $0.url == url } }

    public static func feeds(in languages: Set<String>) -> [CatalogFeed] {
        languages.isEmpty ? feeds : feeds.filter { languages.contains($0.language) }
    }

    /// Languages with feeds in the catalog, in the order the app lists them.
    public static let languages = ["en", "de", "es", "sk", "cs"]

    public static let packs: [StarterPack] = [
        pack("The world today", "What's happening, from four newsrooms", "globe.europe.africa", "en", [
            "https://feeds.bbci.co.uk/news/rss.xml", "https://www.theguardian.com/world/rss",
            "https://feeds.npr.org/1001/rss.xml", "https://www.aljazeera.com/xml/rss/all.xml",
        ]),
        pack("Tech, sorted", "The industry and what people are building", "cpu", "en", [
            "https://hnrss.org/frontpage", "https://www.theverge.com/rss/index.xml",
            "https://feeds.arstechnica.com/arstechnica/index", "https://techcrunch.com/feed/",
        ]),
        pack("Curious mind", "Science and ideas, explained well", "atom", "en", [
            "https://www.quantamagazine.org/feed/", "https://www.nasa.gov/feed/",
            "https://aeon.co/feed.rss", "https://www.sciencedaily.com/rss/all.xml",
        ]),
        pack("Made with care", "Design, art and good writing", "paintpalette", "en", [
            "https://www.dezeen.com/feed/", "https://www.thisiscolossal.com/feed/",
            "https://www.smashingmagazine.com/feed/", "https://www.themarginalian.org/feed/",
        ]),
        pack("Nachrichten", "Der Tag in Deutschland und der Welt", "globe.europe.africa", "de", [
            "https://www.tagesschau.de/infoservices/alle-meldungen-100~rss2.xml",
            "https://www.spiegel.de/schlagzeilen/index.rss", "https://newsfeed.zeit.de/index",
        ]),
        pack("Technik", "IT, Netz und Digitales", "cpu", "de", [
            "https://www.heise.de/rss/heise-atom.xml", "https://rss.golem.de/rss.php?feed=RSS2.0", "https://t3n.de/rss.xml",
        ]),
        pack("Noticias", "Lo más importante del día", "globe.europe.africa", "es", [
            "https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/portada", "https://feeds.bbci.co.uk/mundo/rss.xml",
            "https://www.eldiario.es/rss/",
        ]),
        pack("Tecnología", "Gadgets, internet y software", "cpu", "es", [
            "https://www.xataka.com/feedburner.xml", "https://www.genbeta.com/feedburner.xml",
        ]),
        pack("Správy", "To najdôležitejšie zo Slovenska", "globe.europe.africa", "sk", [
            "https://www.sme.sk/rss-title", "https://dennikn.sk/feed/", "https://www.aktuality.sk/rss/",
        ]),
        pack("Technológie a biznis", "IT, startupy a podnikanie", "cpu", "sk", [
            "https://zive.aktuality.sk/rss/najnovsie/", "https://www.startitup.sk/feed/",
        ]),
        pack("Zprávy", "Co se děje doma i ve světě", "globe.europe.africa", "cs", [
            "https://www.irozhlas.cz/rss/irozhlas", "https://www.seznamzpravy.cz/rss",
            "https://ct24.ceskatelevize.cz/rss/tema/vyber-redakce-84313", "https://denikn.cz/feed/",
        ]),
        pack("Technologie", "Internet, IT a startupy", "cpu", "cs", [
            "https://www.lupa.cz/rss/clanky/", "https://cc.cz/feed/", "https://www.zive.cz/rss/sc-47/",
        ]),
    ]

    private static func pack(_ title: String, _ subtitle: String, _ symbol: String, _ language: String, _ urls: [String]) -> StarterPack {
        StarterPack(title: title, subtitle: subtitle, symbol: symbol, language: language, feedURLs: urls.map { URL(string: $0)! })
    }

    private typealias Entry = (CatalogFeed.Topic, String, String, String, String, String)

    // (topic, title, feed address, site, language, description)
    private static let entries: [Entry] = [
        (.news, "BBC News", "https://feeds.bbci.co.uk/news/rss.xml", "bbc.co.uk", "en", "Top stories from the UK and around the world"),
        (.news, "BBC News – World", "https://feeds.bbci.co.uk/news/world/rss.xml", "bbc.co.uk", "en", "International news from BBC correspondents"),
        (.news, "The Guardian – World", "https://www.theguardian.com/world/rss", "theguardian.com", "en", "World news, analysis and long reads"),
        (.news, "NPR News", "https://feeds.npr.org/1001/rss.xml", "npr.org", "en", "American public radio's news desk"),
        (.news, "Al Jazeera", "https://www.aljazeera.com/xml/rss/all.xml", "aljazeera.com", "en", "Global news with a wide view of the Middle East"),
        (.news, "The New York Times", "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml", "nytimes.com", "en", "The front page of the Times"),
        (.news, "The Atlantic", "https://www.theatlantic.com/feed/all/", "theatlantic.com", "en", "Essays and reporting on politics, culture and ideas"),
        (.news, "DW News", "https://rss.dw.com/rdf/rss-en-all", "dw.com", "en", "Germany's international broadcaster, in English"),
        (.news, "France 24", "https://www.france24.com/en/rss", "france24.com", "en", "International news from Paris"),
        (.news, "Politico", "https://rss.politico.com/politics-news.xml", "politico.com", "en", "Washington politics, close up"),
        (.news, "CBS News", "https://www.cbsnews.com/latest/rss/main", "cbsnews.com", "en", "US and world headlines"),
        (.technology, "Hacker News", "https://hnrss.org/frontpage", "news.ycombinator.com", "en", "The links programmers are talking about today"),
        (.technology, "The Verge", "https://www.theverge.com/rss/index.xml", "theverge.com", "en", "Technology, science and culture"),
        (.technology, "Ars Technica", "https://feeds.arstechnica.com/arstechnica/index", "arstechnica.com", "en", "Deep technical reporting and reviews"),
        (.technology, "Wired", "https://www.wired.com/feed/rss", "wired.com", "en", "How technology is changing everything"),
        (.technology, "TechCrunch", "https://techcrunch.com/feed/", "techcrunch.com", "en", "Startups, funding and the tech industry"),
        (.technology, "Engadget", "https://www.engadget.com/rss.xml", "engadget.com", "en", "Gadgets, games and consumer tech"),
        (.technology, "MIT Technology Review", "https://www.technologyreview.com/feed/", "technologyreview.com", "en", "Emerging technology and its consequences"),
        (.technology, "9to5Mac", "https://9to5mac.com/feed/", "9to5mac.com", "en", "Apple news as it happens"),
        (.technology, "MacRumors", "https://feeds.macrumors.com/MacRumors-All", "macrumors.com", "en", "Apple news, rumors and guides"),
        (.technology, "Daring Fireball", "https://daringfireball.net/feeds/main", "daringfireball.net", "en", "John Gruber on Apple and design"),
        (.technology, "Simon Willison", "https://simonwillison.net/atom/everything/", "simonwillison.net", "en", "Hands-on notes about AI and software"),
        (.technology, "The GitHub Blog", "https://github.blog/feed/", "github.blog", "en", "Updates and engineering from GitHub"),
        (.technology, "The Register", "https://www.theregister.com/headlines.atom", "theregister.com", "en", "Enterprise IT news with a sense of humour"),
        (.technology, "404 Media", "https://www.404media.co/rss/", "404media.co", "en", "Independent reporting on technology and power"),
        (.technology, "Stratechery", "https://stratechery.com/feed/", "stratechery.com", "en", "Ben Thompson on the business of tech"),
        (.science, "NASA", "https://www.nasa.gov/feed/", "nasa.gov", "en", "Missions, discoveries and images from space"),
        (.science, "Quanta Magazine", "https://www.quantamagazine.org/feed/", "quantamagazine.org", "en", "Mathematics, physics and biology, beautifully explained"),
        (.science, "Nature", "https://www.nature.com/nature.rss", "nature.com", "en", "Research and news from the science journal"),
        (.science, "Scientific American", "https://www.scientificamerican.com/platform/syndication/rss/", "scientificamerican.com", "en", "Science news and features for everyone"),
        (.science, "New Scientist", "https://www.newscientist.com/feed/", "newscientist.com", "en", "The latest science and technology stories"),
        (.science, "ScienceDaily", "https://www.sciencedaily.com/rss/all.xml", "sciencedaily.com", "en", "New research, summarised daily"),
        (.science, "Aeon", "https://aeon.co/feed.rss", "aeon.co", "en", "Essays on philosophy, science and culture"),
        (.science, "Phys.org", "https://phys.org/rss-feed/", "phys.org", "en", "Physics, space and earth science news"),
        (.business, "Harvard Business Review", "http://feeds.hbr.org/harvardbusiness", "hbr.org", "en", "Management ideas and research"),
        (.business, "The Economist", "https://www.economist.com/latest/rss.xml", "economist.com", "en", "Global politics, business and economics"),
        (.business, "CNBC", "https://www.cnbc.com/id/100003114/device/rss/rss.html", "cnbc.com", "en", "Markets and business headlines"),
        (.business, "MarketWatch", "https://feeds.content.dowjones.io/public/rss/mw_topstories", "marketwatch.com", "en", "Markets, investing and personal finance"),
        (.business, "Fast Company", "https://www.fastcompany.com/latest/rss", "fastcompany.com", "en", "Innovation, leadership and design in business"),
        (.business, "Financial Times", "https://www.ft.com/rss/home/international", "ft.com", "en", "International business news (many stories need a subscription)"),
        (.design, "Dezeen", "https://www.dezeen.com/feed/", "dezeen.com", "en", "Architecture, interiors and design"),
        (.design, "Smashing Magazine", "https://www.smashingmagazine.com/feed/", "smashingmagazine.com", "en", "Web design and front-end craft"),
        (.design, "Colossal", "https://www.thisiscolossal.com/feed/", "thisiscolossal.com", "en", "Art, craft and visual culture"),
        (.design, "Creative Bloq", "https://www.creativebloq.com/feeds.xml", "creativebloq.com", "en", "Inspiration and tools for designers"),
        (.design, "designboom", "https://www.designboom.com/feed/", "designboom.com", "en", "Architecture and design from around the world"),
        (.design, "Core77", "https://feeds.feedburner.com/core77/blog", "core77.com", "en", "Industrial design and making things"),
        (.culture, "The New Yorker", "https://www.newyorker.com/feed/everything", "newyorker.com", "en", "Reporting, criticism, fiction and humour"),
        (.culture, "Pitchfork", "https://pitchfork.com/feed/feed-news/rss", "pitchfork.com", "en", "Music news"),
        (.culture, "Open Culture", "https://www.openculture.com/feed", "openculture.com", "en", "The best free culture on the web"),
        (.culture, "Kottke", "https://feeds.kottke.org/main", "kottke.org", "en", "Jason Kottke's links to interesting things"),
        (.culture, "The Marginalian", "https://www.themarginalian.org/feed/", "themarginalian.org", "en", "Maria Popova on books, art and meaning"),
        (.culture, "Longreads", "https://longreads.com/feed/", "longreads.com", "en", "Long-form stories worth your time"),
        (.sport, "BBC Sport", "https://feeds.bbci.co.uk/sport/rss.xml", "bbc.co.uk", "en", "Football, cricket, F1 and more"),
        (.sport, "ESPN", "https://www.espn.com/espn/rss/news", "espn.com", "en", "US sports headlines"),
        (.sport, "The Guardian – Sport", "https://www.theguardian.com/uk/sport/rss", "theguardian.com", "en", "Sport news and reports"),
        (.sport, "Sky Sports", "https://www.skysports.com/rss/12040", "skysports.com", "en", "The latest from Sky Sports News"),
        (.news, "tagesschau", "https://www.tagesschau.de/infoservices/alle-meldungen-100~rss2.xml", "tagesschau.de", "de", "Die Nachrichten der ARD"),
        (.news, "DER SPIEGEL", "https://www.spiegel.de/schlagzeilen/index.rss", "spiegel.de", "de", "Schlagzeilen aus Politik, Wirtschaft und Kultur"),
        (.news, "ZEIT ONLINE", "https://newsfeed.zeit.de/index", "zeit.de", "de", "Nachrichten, Hintergründe und Debatten"),
        (.news, "FAZ", "https://www.faz.net/rss/aktuell/", "faz.net", "de", "Aktuelles der Frankfurter Allgemeinen"),
        (.news, "Süddeutsche Zeitung", "https://rss.sueddeutsche.de/rss/Topthemen", "sueddeutsche.de", "de", "Die Topthemen der SZ"),
        (.news, "DW Deutsch", "https://rss.dw.com/rdf/rss-de-all", "dw.com", "de", "Die Deutsche Welle auf Deutsch"),
        (.technology, "heise online", "https://www.heise.de/rss/heise-atom.xml", "heise.de", "de", "IT-Nachrichten seit 1996"),
        (.technology, "Golem", "https://rss.golem.de/rss.php?feed=RSS2.0", "golem.de", "de", "IT-News für Profis"),
        (.technology, "t3n", "https://t3n.de/rss.xml", "t3n.de", "de", "Digitale Wirtschaft und Technik"),
        (.science, "Spektrum", "https://www.spektrum.de/alias/rss/spektrum-de-rss-feed/996406", "spektrum.de", "de", "Wissenschaft verständlich"),
        (.sport, "kicker", "https://newsfeed.kicker.de/news/aktuell", "kicker.de", "de", "Fußball und mehr"),
        (.news, "EL PAÍS", "https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/portada", "elpais.com", "es", "La portada del periódico global"),
        (.news, "BBC News Mundo", "https://feeds.bbci.co.uk/mundo/rss.xml", "bbc.com/mundo", "es", "Noticias internacionales de la BBC en español"),
        (.news, "EL MUNDO", "https://e00-elmundo.uecdn.es/elmundo/rss/portada.xml", "elmundo.es", "es", "La portada de El Mundo"),
        (.news, "elDiario.es", "https://www.eldiario.es/rss/", "eldiario.es", "es", "Periodismo independiente"),
        (.technology, "Xataka", "https://www.xataka.com/feedburner.xml", "xataka.com", "es", "Tecnología y gadgets"),
        (.technology, "Genbeta", "https://www.genbeta.com/feedburner.xml", "genbeta.com", "es", "Software, apps e internet"),
        (.news, "SME", "https://www.sme.sk/rss-title", "sme.sk", "sk", "Hlavné správy denníka SME"),
        (.news, "Denník N", "https://dennikn.sk/feed/", "dennikn.sk", "sk", "Nezávislý denník"),
        (.news, "Aktuality.sk", "https://www.aktuality.sk/rss/", "aktuality.sk", "sk", "Aktuálne spravodajstvo"),
        (.news, "Pravda", "https://www.pravda.sk/spravy/rss/xml", "pravda.sk", "sk", "Správy denníka Pravda"),
        (.news, "TASR – teraz.sk", "https://www.teraz.sk/rss/slovensko.rss", "teraz.sk", "sk", "Správy tlačovej agentúry zo Slovenska"),
        (.news, "Postoj", "https://www.postoj.sk/rss", "postoj.sk", "sk", "Správy a komentáre"),
        (.technology, "Živé.sk", "https://zive.aktuality.sk/rss/najnovsie/", "zive.sk", "sk", "Počítače, IT a internet"),
        (.business, "Startitup", "https://www.startitup.sk/feed/", "startitup.sk", "sk", "Podnikanie, startupy a inovácie"),
        (.news, "iROZHLAS", "https://www.irozhlas.cz/rss/irozhlas", "irozhlas.cz", "cs", "Zpravodajství Českého rozhlasu"),
        (.news, "Novinky.cz", "https://www.novinky.cz/rss", "novinky.cz", "cs", "Nejnovější zprávy"),
        (.news, "Seznam Zprávy", "https://www.seznamzpravy.cz/rss", "seznamzpravy.cz", "cs", "Zprávy z domova i ze světa"),
        (.news, "ČT24", "https://ct24.ceskatelevize.cz/rss/tema/vyber-redakce-84313", "ct24.cz", "cs", "Výběr redakce České televize"),
        (.news, "Aktuálně.cz", "https://www.aktualne.cz/rss/", "aktualne.cz", "cs", "Aktuální zprávy"),
        (.news, "Deník N", "https://denikn.cz/feed/", "denikn.cz", "cs", "Nezávislý deník"),
        (.technology, "Lupa.cz", "https://www.lupa.cz/rss/clanky/", "lupa.cz", "cs", "O českém internetu"),
        (.technology, "CzechCrunch", "https://cc.cz/feed/", "cc.cz", "cs", "Technologie a startupy"),
        (.technology, "Živě.cz", "https://www.zive.cz/rss/sc-47/", "zive.cz", "cs", "Počítače, IT a vědecké novinky"),
    ]
}
