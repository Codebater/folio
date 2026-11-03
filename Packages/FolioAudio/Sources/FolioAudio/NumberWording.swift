import Foundation
import FolioCore

/// Numbers said as words in the segment's language, for natural voices that
/// read digits badly outside English. Supertonic-3 says a year written in
/// digits like no language at all: a language identifier heard a Slovak
/// "2026" as 1 % Slovak, and the same year in words as 100 %. Dates get
/// their spoken form ("3. novembra" → "tretieho novembra", "am 3. November"
/// → "am dritten November"), and times, decimals, percentages and plain
/// numbers their words. English is left as written; Apple voices read
/// digits well and don't use this.
///
/// Ordinals outside dates ("21. storočie", "der 3. Platz") depend on the
/// noun they belong to and stay as written.
enum NumberWording {
    static func edits(for text: String, language: LanguageCode?) -> [PronunciationEdit] {
        guard let base = language?.base, let speller = spellers[base] else { return [] }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var edits: [PronunciationEdit] = []
        var taken = IndexSet()
        func claim(_ range: NSRange, _ replacement: String?) {
            guard let replacement, range.length > 0 else { return }
            let span = range.location..<(range.location + range.length)
            guard !taken.intersects(integersIn: span) else { return }
            taken.insert(integersIn: span)
            edits.append(PronunciationEdit(range: span, replacement: replacement))
        }
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        func before(_ m: NSTextCheckingResult) -> String {
            let start = max(0, m.range.location - 12)
            let words = ns.substring(with: NSRange(location: start, length: m.range.location - start))
                .split(whereSeparator: { !$0.isLetter })
            return words.last.map { String($0).lowercased() } ?? ""
        }

        // Dates first, then times, percentages, and plain numbers last.
        for m in speller.dayMonth.matches(in: text, range: whole) {
            guard let day = group(m, 1).flatMap(Int.init), let month = group(m, 2) else { continue }
            claim(m.range, speller.date(day: day, monthName: month, year: group(m, 3).flatMap(Int.init), before: before(m)))
        }
        if let numericDate = speller.numericDate {
            for m in numericDate.matches(in: text, range: whole) {
                guard let day = group(m, 1).flatMap(Int.init), let month = group(m, 2).flatMap(Int.init),
                      let year = group(m, 3).flatMap(Int.init), (1...12).contains(month) else { continue }
                claim(m.range, speller.date(day: day, month: month, year: year, before: before(m)))
            }
        }
        for m in speller.time.matches(in: text, range: whole) {
            guard let hour = group(m, 1).flatMap(Int.init), let minute = group(m, 2).flatMap(Int.init) else { continue }
            claim(m.range, speller.time(hour: hour, minute: minute, before: before(m)))
        }
        for m in percent.matches(in: text, range: whole) {
            guard let number = group(m, 1).flatMap(parse) else { continue }
            claim(m.range, speller.percent(number))
        }
        for m in plain.matches(in: text, range: whole) {
            guard let raw = group(m, 1), let number = parse(raw) else { continue }
            let after = ns.substring(from: m.range.location + m.range.length)
            // "21. storočie", "der 3. Platz": an ordinal, whose ending depends on the noun.
            if speller.dottedOrdinals, after.hasPrefix("."), after.dropFirst().first == " ",
               let next = after.dropFirst(2).first, next.isLetter, next.isLowercase || base == "de" { continue }
            let nextIsWord = after.first == " " && after.dropFirst().first?.isLetter == true
            let year = number.fraction == nil && speller.isYear(number.whole, before: before(m))
            claim(m.range, year ? speller.year(number.whole) : speller.number(number, nextIsWord: nextIsWord))
        }
        return edits
    }

    struct Number: Equatable {
        var whole: Int
        /// Digits after the decimal comma, as written ("05").
        var fraction: String?
    }

    /// "12 500", "12.500", "4,5", "4.5", "2026". A dot before exactly three
    /// digits groups thousands (German style); otherwise it's a decimal point.
    static func parse(_ raw: String) -> Number? {
        let separators = CharacterSet(charactersIn: " \u{00A0}\u{202F}")
        var text = raw.trimmingCharacters(in: .whitespaces)
        var fraction: String?
        if let comma = text.lastIndex(of: ",") {
            fraction = String(text[text.index(after: comma)...])
            text = String(text[..<comma])
        } else if let dot = text.lastIndex(of: "."), text.distance(from: dot, to: text.endIndex) - 1 != 3 {
            fraction = String(text[text.index(after: dot)...])
            text = String(text[..<dot])
        }
        let digits = String(text.unicodeScalars.filter { !separators.contains($0) && $0 != "." })
        guard !digits.isEmpty, digits.count <= 12, let whole = Int(digits) else { return nil }
        if let f = fraction, f.isEmpty || !f.allSatisfy(\.isNumber) { return nil }
        return Number(whole: whole, fraction: fraction)
    }

    // A number with optional thousands groups and decimals, not glued to letters ("5G", "A4", "COVID-19").
    static let numberPattern = "\\d{1,3}(?:[ \\u00A0\\u202F.]\\d{3})+(?:,\\d+)?|\\d+(?:[.,]\\d+)?"
    static let plain = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}/.,:])(?<!\\p{L}-)(\(numberPattern))(?![\\p{L}\\p{N}/]|-\\p{L}|[.,:]\\d)")
    static let percent = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}.,])(\(numberPattern))\\s?%")

    static let spellers: [String: any NumberSpeller] = ["sk": SlovakNumbers(), "cs": CzechNumbers(), "de": GermanNumbers(), "es": SpanishNumbers()]
}

protocol NumberSpeller: Sendable {
    var dayMonth: NSRegularExpression { get }
    var numericDate: NSRegularExpression? { get }
    var time: NSRegularExpression { get }
    /// "3." before a noun is an ordinal in this language.
    var dottedOrdinals: Bool { get }
    func cardinal(_ n: Int) -> String
    func date(day: Int, monthName: String, year: Int?, before: String) -> String?
    func date(day: Int, month: Int, year: Int, before: String) -> String?
    func time(hour: Int, minute: Int, before: String) -> String?
    /// The number and the word for per cent ("dve percentá").
    func percent(_ number: NumberWording.Number) -> String
    func decimal(_ whole: Int, _ fraction: String) -> String
    func isYear(_ n: Int, before: String) -> Bool
    func year(_ n: Int) -> String
    func adjusted(_ words: String, n: Int, nextIsWord: Bool) -> String
}

extension NumberSpeller {
    func number(_ number: NumberWording.Number, nextIsWord: Bool) -> String? {
        if let fraction = number.fraction { return decimal(number.whole, fraction) }
        return adjusted(cardinal(number.whole), n: number.whole, nextIsWord: nextIsWord)
    }
    func isYear(_ n: Int, before: String) -> Bool { false }
    func year(_ n: Int) -> String { cardinal(n) }
    func adjusted(_ words: String, n: Int, nextIsWord: Bool) -> String { words }

    static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
    static func dottedDayMonth(_ months: [String]) -> NSRegularExpression {
        regex("(?<![\\p{L}\\p{N}.])(\\d{1,2})\\.\\s?(" + months.joined(separator: "|") + ")(?:\\s+(\\d{4}))?(?![\\p{L}\\p{N}])")
    }
    static var dottedNumericDate: NSRegularExpression {
        regex("(?<![\\p{L}\\p{N}.])(\\d{1,2})\\.\\s?(\\d{1,2})\\.\\s?(\\d{4})(?!\\p{N})")
    }
    /// Digits one by one ("05" → "nula päť").
    func digits(_ text: String) -> String {
        text.compactMap { $0.wholeNumberValue }.map(cardinal).joined(separator: " ")
    }
    /// Groups of three digits with this language's words for thousand, million, billion.
    func grouped(_ n: Int, below1000: (Int) -> String, scale: (Int, Int) -> String, joiner: String = " ") -> String {
        guard n >= 1000 else { return below1000(n) }
        var parts: [String] = []
        var rest = n
        for (power, size) in [(3, 1_000_000_000), (2, 1_000_000), (1, 1000)] where rest >= size {
            parts.append(scale(rest / size, power))
            rest %= size
        }
        if rest > 0 { parts.append(below1000(rest)) }
        return parts.joined(separator: joiner)
    }
}

// MARK: Slovak

struct SlovakNumbers: NumberSpeller {
    static let units = ["nula", "jeden", "dva", "tri", "štyri", "päť", "šesť", "sedem", "osem", "deväť"]
    static let teens = ["desať", "jedenásť", "dvanásť", "trinásť", "štrnásť", "pätnásť", "šestnásť", "sedemnásť", "osemnásť", "devätnásť"]
    static let tens = ["", "", "dvadsať", "tridsať", "štyridsať", "päťdesiat", "šesťdesiat", "sedemdesiat", "osemdesiat", "deväťdesiat"]
    static let hundreds = ["", "sto", "dvesto", "tristo", "štyristo", "päťsto", "šesťsto", "sedemsto", "osemsto", "deväťsto"]
    static let genitiveMonths = ["januára", "februára", "marca", "apríla", "mája", "júna", "júla", "augusta", "septembra", "októbra", "novembra", "decembra"]
    static let dativeMonths = ["januáru", "februáru", "marcu", "aprílu", "máju", "júnu", "júlu", "augustu", "septembru", "októbru", "novembru", "decembru"]
    /// Ordinals in the genitive ("tretieho" novembra), 1–31.
    static let ordinalOnes = ["", "prvého", "druhého", "tretieho", "štvrtého", "piateho", "šiesteho", "siedmeho", "ôsmeho", "deviateho"]
    static let ordinalTeens = ["desiateho", "jedenásteho", "dvanásteho", "trinásteho", "štrnásteho", "pätnásteho", "šestnásteho",
                               "sedemnásteho", "osemnásteho", "devätnásteho"]

    let dayMonth = Self.dottedDayMonth(Self.genitiveMonths + Self.dativeMonths)
    let numericDate: NSRegularExpression? = Self.dottedNumericDate
    let time = Self.regex("(?<![\\p{L}\\p{N}:.,])([01]?\\d|2[0-3]):([0-5]\\d)(?![\\p{N}:])(?:\\s?hod\\.)?")
    let dottedOrdinals = true

    func below1000(_ n: Int) -> String {
        var words: [String] = []
        if n >= 100 { words.append(Self.hundreds[n / 100]) }
        let rest = n % 100
        if rest >= 20 { words.append(Self.tens[rest / 10] + (rest % 10 > 0 ? Self.units[rest % 10] : "")) }
        else if rest >= 10 { words.append(Self.teens[rest - 10]) }
        else if rest > 0 || n == 0 { words.append(Self.units[rest]) }
        return words.joined()
    }

    func cardinal(_ n: Int) -> String {
        grouped(n, below1000: below1000) { count, power in
            switch power {
            case 1: return count == 1 ? "tisíc" : (count == 2 ? "dve" : below1000(count)) + "tisíc"
            case 2: return count == 1 ? "milión" : below1000(count) + ((2...4).contains(count) ? " milióny" : " miliónov")
            default: return count == 1 ? "miliarda" : (count == 2 ? "dve" : below1000(count)) + ((2...4).contains(count) ? " miliardy" : " miliárd")
            }
        }
    }

    func ordinalGenitive(_ n: Int) -> String? {
        switch n {
        case 1...9: return Self.ordinalOnes[n]
        case 10...19: return Self.ordinalTeens[n - 10]
        case 20...31:
            let tens = n >= 30 ? "tridsiateho" : "dvadsiateho"
            return n % 10 == 0 ? tens : tens + " " + Self.ordinalOnes[n % 10]
        default: return nil
        }
    }

    func date(day: Int, monthName: String, year: Int?, before: String) -> String? {
        guard var ordinal = ordinalGenitive(day) else { return nil }
        // "k 3. novembru": the dative.
        if Self.dativeMonths.contains(monthName.lowercased()) {
            ordinal = ordinal.replacingOccurrences(of: "ého", with: "ému").replacingOccurrences(of: "eho", with: "emu")
        }
        return [ordinal, monthName, year.map(cardinal)].compactMap { $0 }.joined(separator: " ")
    }

    func date(day: Int, month: Int, year: Int, before: String) -> String? {
        ordinalGenitive(day).map { "\($0) \(Self.genitiveMonths[month - 1]) \(cardinal(year))" }
    }

    func time(hour: Int, minute: Int, before: String) -> String? {
        let minutes = minute == 0 ? nil : (minute < 10 ? "nula " + Self.units[minute] : cardinal(minute))
        // "o 14:30" → "o štrnástej tridsať": the hour as a feminine ordinal.
        if before == "o", let genitive = hour == 0 ? "nultého" : ordinalGenitive(hour) {
            let feminine = genitive.split(separator: " ").map { word -> String in
                for ending in ["ieho", "eho", "ého"] where word.hasSuffix(ending) { return String(word.dropLast(ending.count)) + "ej" }
                return String(word)
            }.joined(separator: " ")
            return [feminine, minutes].compactMap { $0 }.joined(separator: " ")
        }
        return [cardinal(hour), minutes ?? "hodín"].joined(separator: " ")
    }

    func decimal(_ whole: Int, _ fraction: String) -> String {
        let point: String
        switch whole {
        case 0: point = "nula celá"
        case 1: point = "jedna celá"
        case 2: point = "dve celé"
        case 3, 4: point = cardinal(whole) + " celé"
        default: point = cardinal(whole) + " celých"
        }
        return point + " " + (fraction.hasPrefix("0") || fraction.count > 2 ? digits(fraction) : cardinal(Int(fraction) ?? 0))
    }

    func percent(_ number: NumberWording.Number) -> String {
        if let fraction = number.fraction { return decimal(number.whole, fraction) + " percenta" }
        switch number.whole {
        case 1: return "jedno percento"
        case 2: return "dve percentá"
        case 3, 4: return cardinal(number.whole) + " percentá"
        default: return cardinal(number.whole) + " percent"
        }
    }
}

// MARK: Czech

struct CzechNumbers: NumberSpeller {
    static let units = ["nula", "jeden", "dva", "tři", "čtyři", "pět", "šest", "sedm", "osm", "devět"]
    static let teens = ["deset", "jedenáct", "dvanáct", "třináct", "čtrnáct", "patnáct", "šestnáct", "sedmnáct", "osmnáct", "devatenáct"]
    static let tens = ["", "", "dvacet", "třicet", "čtyřicet", "padesát", "šedesát", "sedmdesát", "osmdesát", "devadesát"]
    static let hundreds = ["", "sto", "dvě stě", "tři sta", "čtyři sta", "pět set", "šest set", "sedm set", "osm set", "devět set"]
    static let genitiveMonths = ["ledna", "února", "března", "dubna", "května", "června", "července", "srpna", "září", "října", "listopadu", "prosince"]
    static let ordinalOnes = ["", "prvního", "druhého", "třetího", "čtvrtého", "pátého", "šestého", "sedmého", "osmého", "devátého"]
    static let ordinalTeens = ["desátého", "jedenáctého", "dvanáctého", "třináctého", "čtrnáctého", "patnáctého", "šestnáctého",
                               "sedmnáctého", "osmnáctého", "devatenáctého"]

    let dayMonth = Self.dottedDayMonth(Self.genitiveMonths)
    let numericDate: NSRegularExpression? = Self.dottedNumericDate
    let time = Self.regex("(?<![\\p{L}\\p{N}:.,])([01]?\\d|2[0-3]):([0-5]\\d)(?![\\p{N}:])(?:\\s?hod\\.)?")
    let dottedOrdinals = true

    func below1000(_ n: Int) -> String {
        var words: [String] = []
        if n >= 100 { words.append(Self.hundreds[n / 100]) }
        let rest = n % 100
        if rest >= 20 { words.append(Self.tens[rest / 10]); if rest % 10 > 0 { words.append(Self.units[rest % 10]) } }
        else if rest >= 10 { words.append(Self.teens[rest - 10]) }
        else if rest > 0 || n == 0 { words.append(Self.units[rest]) }
        return words.joined(separator: " ")
    }

    func cardinal(_ n: Int) -> String {
        grouped(n, below1000: below1000) { count, power in
            let few = (2...4).contains(count)
            switch power {
            case 1: return count == 1 ? "tisíc" : below1000(count) + (few ? " tisíce" : " tisíc")
            case 2: return count == 1 ? "milion" : below1000(count) + (few ? " miliony" : " milionů")
            default: return count == 1 ? "miliarda" : (count == 2 ? "dvě" : below1000(count)) + (few ? " miliardy" : " miliard")
            }
        }
    }

    func ordinalGenitive(_ n: Int) -> String? {
        switch n {
        case 1...9: return Self.ordinalOnes[n]
        case 10...19: return Self.ordinalTeens[n - 10]
        case 20...31:
            let tens = n >= 30 ? "třicátého" : "dvacátého"
            return n % 10 == 0 ? tens : tens + " " + Self.ordinalOnes[n % 10]
        default: return nil
        }
    }

    func date(day: Int, monthName: String, year: Int?, before: String) -> String? {
        ordinalGenitive(day).map { [$0, monthName, year.map(cardinal)].compactMap { $0 }.joined(separator: " ") }
    }

    func date(day: Int, month: Int, year: Int, before: String) -> String? {
        ordinalGenitive(day).map { "\($0) \(Self.genitiveMonths[month - 1]) \(cardinal(year))" }
    }

    func time(hour: Int, minute: Int, before: String) -> String? {
        if minute == 0 { return cardinal(hour) + (hour == 1 ? " hodina" : ((2...4).contains(hour) ? " hodiny" : " hodin")) }
        return cardinal(hour) + " " + (minute < 10 ? "nula " + Self.units[minute] : cardinal(minute))
    }

    func decimal(_ whole: Int, _ fraction: String) -> String {
        let point: String
        switch whole {
        case 0: point = "nula celá"
        case 1: point = "jedna celá"
        case 2: point = "dvě celé"
        case 3, 4: point = cardinal(whole) + " celé"
        default: point = cardinal(whole) + " celých"
        }
        return point + " " + (fraction.hasPrefix("0") || fraction.count > 2 ? digits(fraction) : cardinal(Int(fraction) ?? 0))
    }

    func percent(_ number: NumberWording.Number) -> String {
        if let fraction = number.fraction { return decimal(number.whole, fraction) + " procenta" }
        switch number.whole {
        case 1: return "jedno procento"
        case 2: return "dvě procenta"
        case 3, 4: return cardinal(number.whole) + " procenta"
        default: return cardinal(number.whole) + " procent"
        }
    }
}

// MARK: German

struct GermanNumbers: NumberSpeller {
    static let units = ["null", "eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun"]
    static let teens = ["zehn", "elf", "zwölf", "dreizehn", "vierzehn", "fünfzehn", "sechzehn", "siebzehn", "achtzehn", "neunzehn"]
    static let tens = ["", "", "zwanzig", "dreißig", "vierzig", "fünfzig", "sechzig", "siebzig", "achtzig", "neunzig"]
    static let months = ["Januar", "Jänner", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"]
    /// Words before a number that make it a year ("im Jahr 1989", "seit 2020").
    static let yearCues: Set<String> = ["jahr", "jahre", "jahres", "jahrs", "im", "seit", "bis", "ab", "von", "anfang", "ende", "mitte", "sommer", "winter", "frühjahr", "herbst"]

    let dayMonth = Self.dottedDayMonth(Self.months)
    let numericDate: NSRegularExpression? = Self.dottedNumericDate
    // "14:30", "14:30 Uhr", "14.30 Uhr" (a dot only before "Uhr"; otherwise it's a decimal).
    let time = Self.regex("(?<![\\p{L}\\p{N}:.,])([01]?\\d|2[0-3])(?::|\\.(?=[0-5]\\d\\s?Uhr))([0-5]\\d)(?:\\s?Uhr)?(?![\\p{N}:\\p{L}])")
    let dottedOrdinals = true

    /// "ein" inside compounds (einundzwanzig, einhundert).
    func below1000(_ n: Int) -> String {
        var words = ""
        if n >= 100 { words += (n / 100 == 1 ? "ein" : Self.units[n / 100]) + "hundert" }
        let rest = n % 100
        if rest >= 20 { words += (rest % 10 > 0 ? (rest % 10 == 1 ? "ein" : Self.units[rest % 10]) + "und" : "") + Self.tens[rest / 10] }
        else if rest >= 10 { words += Self.teens[rest - 10] }
        else if rest > 0 || n == 0 { words += Self.units[rest] }
        return words
    }

    func cardinal(_ n: Int) -> String {
        grouped(n, below1000: below1000, scale: { count, power in
            switch power {
            case 1: return (count == 1 ? "ein" : below1000(count)) + "tausend"
            case 2: return count == 1 ? "eine Million " : below1000(count) + " Millionen "
            default: return count == 1 ? "eine Milliarde " : below1000(count) + " Milliarden "
            }
        }, joiner: "").trimmingCharacters(in: .whitespaces)
    }

    /// Ordinal stem without its ending: "drit", "zwanzigs".
    func ordinalStem(_ n: Int) -> String {
        switch n {
        case 1: return "ers"
        case 3: return "drit"
        case 7: return "sieb"
        case 8: return "ach"
        case 2...19: return cardinal(n)
        default: return cardinal(n) + "s"
        }
    }

    /// "der 3. November" → "der dritte November"; otherwise (am, vom, bis zum, den) "dritten".
    func ordinal(_ n: Int, before: String) -> String { ordinalStem(n) + (before == "der" ? "te" : "ten") }

    func date(day: Int, monthName: String, year: Int?, before: String) -> String? {
        guard (1...31).contains(day) else { return nil }
        return [ordinal(day, before: before), monthName, year.map(self.year)].compactMap { $0 }.joined(separator: " ")
    }

    func date(day: Int, month: Int, year: Int, before: String) -> String? {
        guard (1...31).contains(day) else { return nil }
        return "\(ordinal(day, before: before)) \(ordinal(month, before: "")) \(self.year(year))"
    }

    func time(hour: Int, minute: Int, before: String) -> String? {
        let h = hour == 1 ? "ein" : cardinal(hour)
        return minute == 0 ? "\(h) Uhr" : "\(h) Uhr \(cardinal(minute))"
    }

    func decimal(_ whole: Int, _ fraction: String) -> String { cardinal(whole) + " Komma " + digits(fraction) }
    func percent(_ number: NumberWording.Number) -> String { (self.number(number, nextIsWord: true) ?? "") + " Prozent" }
    func isYear(_ n: Int, before: String) -> Bool { (1100...2099).contains(n) && Self.yearCues.contains(before) }
    /// 1989 → "neunzehnhundertneunundachtzig"; 2026 → "zweitausendsechsundzwanzig".
    func year(_ n: Int) -> String {
        guard (1100...1999).contains(n) else { return cardinal(n) }
        return below1000(n / 100) + "hundert" + (n % 100 > 0 ? below1000(n % 100) : "")
    }
    /// "1 Prozent" → "ein Prozent"; "1" alone → "eins".
    func adjusted(_ words: String, n: Int, nextIsWord: Bool) -> String {
        nextIsWord && words.hasSuffix("eins") ? String(words.dropLast()) : words
    }
}

// MARK: Spanish

struct SpanishNumbers: NumberSpeller {
    static let below30 = ["cero", "uno", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve", "diez", "once", "doce",
                          "trece", "catorce", "quince", "dieciséis", "diecisiete", "dieciocho", "diecinueve", "veinte", "veintiuno",
                          "veintidós", "veintitrés", "veinticuatro", "veinticinco", "veintiséis", "veintisiete", "veintiocho", "veintinueve"]
    static let tens = ["", "", "", "treinta", "cuarenta", "cincuenta", "sesenta", "setenta", "ochenta", "noventa"]
    static let hundreds = ["", "ciento", "doscientos", "trescientos", "cuatrocientos", "quinientos", "seiscientos", "setecientos",
                           "ochocientos", "novecientos"]
    static let months = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "setiembre", "octubre",
                         "noviembre", "diciembre"]

    let dayMonth = Self.regex("(?<![\\p{L}\\p{N}])(\\d{1,2})\\s+de\\s+(" + Self.months.joined(separator: "|") + ")(?:\\s+de\\s+(\\d{4}))?(?![\\p{L}\\p{N}])")
    let numericDate: NSRegularExpression? = nil
    let time = Self.regex("(?<![\\p{L}\\p{N}:.,])([01]?\\d|2[0-3]):([0-5]\\d)(?![\\p{N}:])(?:\\s?h\\b)?")
    let dottedOrdinals = false

    func below1000(_ n: Int) -> String {
        if n == 100 { return "cien" }
        var words: [String] = []
        if n >= 100 { words.append(Self.hundreds[n / 100]) }
        let rest = n % 100
        if rest >= 30 { words.append(Self.tens[rest / 10] + (rest % 10 > 0 ? " y " + Self.below30[rest % 10] : "")) }
        else if rest > 0 || n == 0 { words.append(Self.below30[rest]) }
        return words.joined(separator: " ")
    }

    func cardinal(_ n: Int) -> String {
        grouped(n, below1000: below1000) { count, power in
            switch power {
            case 1: return count == 1 ? "mil" : shortened(below1000(count)) + " mil"
            case 2: return count == 1 ? "un millón" : shortened(below1000(count)) + " millones"
            default: return count == 1 ? "mil millones" : shortened(below1000(count)) + " mil millones"
            }
        }
    }

    /// "veintiuno" before a noun: "veintiún", "uno" → "un".
    func shortened(_ words: String) -> String {
        if words.hasSuffix("veintiuno") { return String(words.dropLast(3)) + "ún" }
        if words.hasSuffix("uno") { return String(words.dropLast(1)) }
        return words
    }

    func date(day: Int, monthName: String, year: Int?, before: String) -> String? {
        guard (1...31).contains(day) else { return nil }
        let first = day == 1 ? "primero" : cardinal(day)
        return "\(first) de \(monthName)" + (year.map { " de \(cardinal($0))" } ?? "")
    }

    func date(day: Int, month: Int, year: Int, before: String) -> String? { nil }

    func time(hour: Int, minute: Int, before: String) -> String? {
        let h = hour == 1 ? "una" : cardinal(hour)
        if minute == 0 { return before == "las" || before == "la" ? h : h + (hour == 1 ? " hora" : " horas") }
        return h + " " + (minute < 10 ? "cero " + Self.below30[minute] : cardinal(minute))
    }

    func decimal(_ whole: Int, _ fraction: String) -> String {
        cardinal(whole) + " coma " + (fraction.hasPrefix("0") || fraction.count > 2 ? digits(fraction) : cardinal(Int(fraction) ?? 0))
    }

    func percent(_ number: NumberWording.Number) -> String { (self.number(number, nextIsWord: false) ?? "") + " por ciento" }
    func adjusted(_ words: String, n: Int, nextIsWord: Bool) -> String { nextIsWord ? shortened(words) : words }
}
