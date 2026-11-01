import Foundation

/// HTML character references. Used for feed titles (servers often send them
/// escaped) and by FolioReader's tokenizer for text and attribute values.
public enum HTMLText {
    /// Decodes `&amp;`, `&#233;`, `&#xE9;` and the named references in
    /// `namedEntities`. Unknown references are left as written, like browsers.
    public static func decodeEntities(_ text: some StringProtocol) -> String {
        let source = String(text)
        guard source.contains("&") else { return source }
        var out = String.UnicodeScalarView()
        let scalars = Array(source.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if scalar == "&", let (decoded, length) = decodeReference(scalars, at: i) {
                out.append(contentsOf: decoded)
                i += length
            } else {
                out.append(scalar)
                i += 1
            }
        }
        return String(out)
    }

    /// Tries to decode the reference starting at `scalars[start]` (an "&").
    /// Returns the decoded scalars and how many source scalars were consumed.
    static func decodeReference(_ scalars: [Unicode.Scalar], at start: Int) -> ([Unicode.Scalar], Int)? {
        var j = start + 1
        guard j < scalars.count else { return nil }
        if scalars[j] == "#" {
            j += 1
            var isHex = false
            if j < scalars.count, scalars[j] == "x" || scalars[j] == "X" {
                isHex = true
                j += 1
            }
            let digitsStart = j
            var value: UInt32 = 0
            while j < scalars.count, j - digitsStart < 8 {
                let s = scalars[j]
                guard let digit = isHex ? hexValue(s) : decimalValue(s) else { break }
                value = value &* (isHex ? 16 : 10) &+ digit
                j += 1
            }
            guard j > digitsStart else { return nil }
            if j < scalars.count, scalars[j] == ";" { j += 1 }
            return ([numericScalar(value)], j - start)
        }
        // Named reference: letters and digits, then ";".
        var name = ""
        while j < scalars.count, j - start <= 32, scalars[j].properties.isASCIIHexDigit || isASCIIAlnum(scalars[j]) {
            name.unicodeScalars.append(scalars[j])
            j += 1
        }
        guard !name.isEmpty else { return nil }
        if j < scalars.count, scalars[j] == ";" {
            if let value = namedEntities[name] { return ([value], j + 1 - start) }
            return nil
        }
        // Legacy references browsers accept without a semicolon.
        for legacy in ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg"] where name.hasPrefix(legacy) {
            let next = start + 1 + legacy.unicodeScalars.count
            if next < scalars.count, isASCIIAlnum(scalars[next]) || scalars[next] == "=" { continue }
            return ([namedEntities[legacy]!], next - start)
        }
        return nil
    }

    static func numericScalar(_ value: UInt32) -> Unicode.Scalar {
        // Windows-1252 code points that feeds still emit as &#150; and friends.
        if (0x80...0x9F).contains(value), let mapped = windows1252[value] { return mapped }
        if value == 0 || (0xD800...0xDFFF).contains(value) || value > 0x10FFFF { return "\u{FFFD}" }
        return Unicode.Scalar(value) ?? "\u{FFFD}"
    }

    static func hexValue(_ s: Unicode.Scalar) -> UInt32? {
        switch s.value {
        case 0x30...0x39: s.value - 0x30
        case 0x41...0x46: s.value - 0x41 + 10
        case 0x61...0x66: s.value - 0x61 + 10
        default: nil
        }
    }

    static func decimalValue(_ s: Unicode.Scalar) -> UInt32? {
        (0x30...0x39).contains(s.value) ? s.value - 0x30 : nil
    }

    static func isASCIIAlnum(_ s: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(s.value) || (0x41...0x5A).contains(s.value) || (0x61...0x7A).contains(s.value)
    }

    static let windows1252: [UInt32: Unicode.Scalar] = [
        0x80: "\u{20AC}", 0x82: "\u{201A}", 0x83: "\u{0192}", 0x84: "\u{201E}", 0x85: "\u{2026}", 0x86: "\u{2020}",
        0x87: "\u{2021}", 0x88: "\u{02C6}", 0x89: "\u{2030}", 0x8A: "\u{0160}", 0x8B: "\u{2039}", 0x8C: "\u{0152}",
        0x8E: "\u{017D}", 0x91: "\u{2018}", 0x92: "\u{2019}", 0x93: "\u{201C}", 0x94: "\u{201D}", 0x95: "\u{2022}",
        0x96: "\u{2013}", 0x97: "\u{2014}", 0x98: "\u{02DC}", 0x99: "\u{2122}", 0x9A: "\u{0161}", 0x9B: "\u{203A}",
        0x9C: "\u{0153}", 0x9E: "\u{017E}", 0x9F: "\u{0178}",
    ]

    /// HTML 4 entities plus the HTML5 names that show up in real feeds.
    public static let namedEntities: [String: Unicode.Scalar] = {
        var table: [String: UInt32] = [
            "quot": 34, "amp": 38, "apos": 39, "lt": 60, "gt": 62,
            "OElig": 338, "oelig": 339, "Scaron": 352, "scaron": 353, "Yuml": 376, "fnof": 402, "circ": 710, "tilde": 732,
            "ensp": 8194, "emsp": 8195, "thinsp": 8201, "zwnj": 8204, "zwj": 8205, "lrm": 8206, "rlm": 8207,
            "ndash": 8211, "mdash": 8212, "lsquo": 8216, "rsquo": 8217, "sbquo": 8218, "ldquo": 8220, "rdquo": 8221,
            "bdquo": 8222, "dagger": 8224, "Dagger": 8225, "bull": 8226, "hellip": 8230, "permil": 8240, "prime": 8242,
            "Prime": 8243, "lsaquo": 8249, "rsaquo": 8250, "oline": 8254, "frasl": 8260, "euro": 8364, "image": 8465,
            "weierp": 8472, "real": 8476, "trade": 8482, "alefsym": 8501, "larr": 8592, "uarr": 8593, "rarr": 8594,
            "darr": 8595, "harr": 8596, "crarr": 8629, "lArr": 8656, "uArr": 8657, "rArr": 8658, "dArr": 8659,
            "hArr": 8660, "forall": 8704, "part": 8706, "exist": 8707, "empty": 8709, "nabla": 8711, "isin": 8712,
            "notin": 8713, "ni": 8715, "prod": 8719, "sum": 8721, "minus": 8722, "lowast": 8727, "radic": 8730,
            "prop": 8733, "infin": 8734, "ang": 8736, "and": 8743, "or": 8744, "cap": 8745, "cup": 8746, "int": 8747,
            "there4": 8756, "sim": 8764, "cong": 8773, "asymp": 8776, "ne": 8800, "equiv": 8801, "le": 8804,
            "ge": 8805, "sub": 8834, "sup": 8835, "nsub": 8836, "sube": 8838, "supe": 8839, "oplus": 8853,
            "otimes": 8855, "perp": 8869, "sdot": 8901, "lceil": 8968, "rceil": 8969, "lfloor": 8970, "rfloor": 8971,
            "lang": 9001, "rang": 9002, "loz": 9674, "spades": 9824, "clubs": 9827, "hearts": 9829, "diams": 9830,
            "thetasym": 977, "upsih": 978, "piv": 982, "sigmaf": 962,
            // HTML5 names seen in feeds
            "Tab": 9, "NewLine": 10, "excl": 33, "num": 35, "dollar": 36, "percnt": 37, "lpar": 40, "rpar": 41,
            "ast": 42, "plus": 43, "comma": 44, "period": 46, "sol": 47, "colon": 58, "semi": 59, "equals": 61,
            "quest": 63, "commat": 64, "lsqb": 91, "bsol": 92, "rsqb": 93, "Hat": 94, "lowbar": 95, "grave": 96,
            "lcub": 123, "verbar": 124, "vert": 124, "rcub": 125, "ZeroWidthSpace": 8203, "hyphen": 8208,
            "dash": 8208, "horbar": 8213, "nldr": 8229, "mldr": 8230, "rsquor": 8217, "lsquor": 8218,
            "ldquor": 8222, "check": 10003, "cross": 10007, "star": 9734, "starf": 9733, "nbsp": 160,
            "Ccaron": 268, "ccaron": 269, "Dcaron": 270, "dcaron": 271, "Ecaron": 282, "ecaron": 283,
            "Lcaron": 317, "lcaron": 318, "Ncaron": 327, "ncaron": 328, "Rcaron": 344, "rcaron": 345,
            "Tcaron": 356, "tcaron": 357, "Zcaron": 381, "zcaron": 382, "Uring": 366, "uring": 367,
            "Lacute": 313, "lacute": 314, "Racute": 340, "racute": 341, "Odblac": 336, "odblac": 337,
            "Udblac": 368, "udblac": 369,
        ]
        // Latin-1 supplement, U+00A0 through U+00FF, in code point order.
        let latin1 = """
            nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn sup2 sup3 \
            acute micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave Aacute Acirc Atilde \
            Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute \
            Ocirc Otilde Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN szlig agrave aacute acirc atilde \
            auml aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml eth ntilde ograve oacute \
            ocirc otilde ouml divide oslash ugrave uacute ucirc uuml yacute thorn yuml
            """
        for (offset, name) in latin1.split(separator: " ").enumerated() { table[String(name)] = 160 + UInt32(offset) }
        let greekUpper = "Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota Kappa Lambda Mu Nu Xi Omicron Pi Rho"
        for (offset, name) in greekUpper.split(separator: " ").enumerated() { table[String(name)] = 913 + UInt32(offset) }
        for (offset, name) in "Sigma Tau Upsilon Phi Chi Psi Omega".split(separator: " ").enumerated() {
            table[String(name)] = 931 + UInt32(offset)
        }
        for (offset, name) in greekUpper.lowercased().split(separator: " ").enumerated() {
            table[String(name)] = 945 + UInt32(offset)
        }
        for (offset, name) in "sigma tau upsilon phi chi psi omega".split(separator: " ").enumerated() {
            table[String(name)] = 963 + UInt32(offset)
        }
        return table.compactMapValues(Unicode.Scalar.init)
    }()
}
