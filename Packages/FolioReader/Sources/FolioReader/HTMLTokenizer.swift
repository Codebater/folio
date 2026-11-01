import Foundation
import FolioCore

enum HTMLToken: Equatable, Sendable {
    case startTag(name: String, attributes: [String: String], selfClosing: Bool)
    case endTag(name: String)
    case text(String)
}

/// A forgiving HTML tokenizer for feed content.
///
/// It is not a full HTML5 parser: it only has to split real-world article
/// markup into tags and text reliably, drop comments, doctypes and the
/// contents of script-like elements, and decode character references. Tree
/// building happens in `ArticleParser`, which only keeps allow-listed
/// structure, so malformed input can at worst lose formatting, never inject
/// markup.
enum HTMLTokenizer {
    /// Elements whose content is never shown (and must never be parsed as markup).
    static let rawTextElements: Set<String> = [
        "script", "style", "textarea", "title", "xmp", "noembed", "noframes", "template", "iframe", "plaintext",
    ]

    static func tokenize(_ html: String) -> [HTMLToken] {
        let s = Array(html.unicodeScalars)
        var tokens: [HTMLToken] = []
        var text = String.UnicodeScalarView()
        var i = 0

        func flushText() {
            guard !text.isEmpty else { return }
            tokens.append(.text(HTMLText.decodeEntities(String(text))))
            text.removeAll(keepingCapacity: true)
        }

        while i < s.count {
            let c = s[i]
            guard c == "<", i + 1 < s.count else {
                text.append(c)
                i += 1
                continue
            }
            let next = s[i + 1]
            if next == "!" {
                flushText()
                if matches(s, at: i, "<!--") {
                    i = indexAfter(s, from: i + 4, terminator: "-->")
                } else {
                    i = indexAfter(s, from: i + 2, terminator: ">")
                }
            } else if next == "?" {
                flushText()
                i = indexAfter(s, from: i + 2, terminator: ">")
            } else if next == "/" {
                guard i + 2 < s.count, isASCIILetter(s[i + 2]) else {
                    text.append(c)
                    i += 1
                    continue
                }
                flushText()
                var j = i + 2
                var name = ""
                while j < s.count, !isSpace(s[j]), s[j] != ">", s[j] != "/" {
                    name.unicodeScalars.append(s[j])
                    j += 1
                }
                tokens.append(.endTag(name: name.lowercased()))
                i = indexAfter(s, from: j, terminator: ">")
            } else if isASCIILetter(next) {
                flushText()
                let (token, end) = readStartTag(s, from: i + 1)
                tokens.append(token)
                i = end
                if case .startTag(let name, _, let selfClosing) = token, !selfClosing, rawTextElements.contains(name) {
                    i = skipRawText(s, from: i, name: name)
                    tokens.append(.endTag(name: name))
                }
            } else {
                text.append(c)
                i += 1
            }
        }
        flushText()
        return tokens
    }

    private static func readStartTag(_ s: [Unicode.Scalar], from start: Int) -> (HTMLToken, Int) {
        var j = start
        var name = ""
        while j < s.count, !isSpace(s[j]), s[j] != ">", s[j] != "/" {
            name.unicodeScalars.append(s[j])
            j += 1
        }
        var attributes: [String: String] = [:]
        var selfClosing = false
        while j < s.count {
            while j < s.count, isSpace(s[j]) { j += 1 }
            guard j < s.count else { break }
            if s[j] == ">" {
                j += 1
                break
            }
            if s[j] == "/" {
                if j + 1 < s.count, s[j + 1] == ">" {
                    selfClosing = true
                    j += 2
                    break
                }
                j += 1
                continue
            }
            var attrName = ""
            while j < s.count, !isSpace(s[j]), s[j] != "=", s[j] != ">", !(s[j] == "/" && j + 1 < s.count && s[j + 1] == ">") {
                attrName.unicodeScalars.append(s[j])
                j += 1
            }
            while j < s.count, isSpace(s[j]) { j += 1 }
            var value = ""
            if j < s.count, s[j] == "=" {
                j += 1
                while j < s.count, isSpace(s[j]) { j += 1 }
                if j < s.count, s[j] == "\"" || s[j] == "'" {
                    let quote = s[j]
                    j += 1
                    while j < s.count, s[j] != quote {
                        value.unicodeScalars.append(s[j])
                        j += 1
                    }
                    j += 1
                } else {
                    while j < s.count, !isSpace(s[j]), s[j] != ">" {
                        value.unicodeScalars.append(s[j])
                        j += 1
                    }
                }
            }
            let key = attrName.lowercased()
            if !key.isEmpty, attributes[key] == nil {
                attributes[key] = HTMLText.decodeEntities(value)
            }
            if attrName.isEmpty { j += 1 }  // stray character; never loop forever
        }
        return (.startTag(name: name.lowercased(), attributes: attributes, selfClosing: selfClosing), min(j, s.count))
    }

    /// Skips to just before `</name`, case-insensitively, and past its ">".
    private static func skipRawText(_ s: [Unicode.Scalar], from start: Int, name: String) -> Int {
        let closing = Array("</\(name)".unicodeScalars)
        var j = start
        while j < s.count {
            if s[j] == "<", j + closing.count <= s.count {
                var match = true
                for k in 0..<closing.count where lower(s[j + k]) != closing[k] {
                    match = false
                    break
                }
                if match { return indexAfter(s, from: j + closing.count, terminator: ">") }
            }
            j += 1
        }
        return s.count
    }

    private static func indexAfter(_ s: [Unicode.Scalar], from start: Int, terminator: String) -> Int {
        let t = Array(terminator.unicodeScalars)
        var j = start
        while j + t.count <= s.count {
            if s[j] == t[0], Array(s[j..<(j + t.count)]) == t { return j + t.count }
            j += 1
        }
        return s.count
    }

    private static func matches(_ s: [Unicode.Scalar], at i: Int, _ literal: String) -> Bool {
        let l = Array(literal.unicodeScalars)
        return i + l.count <= s.count && Array(s[i..<(i + l.count)]) == l
    }

    private static func isSpace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}"
    }

    private static func isASCIILetter(_ c: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(c.value) || (0x61...0x7A).contains(c.value)
    }

    private static func lower(_ c: Unicode.Scalar) -> Unicode.Scalar {
        (0x41...0x5A).contains(c.value) ? Unicode.Scalar(c.value + 32)! : c
    }
}
