import Foundation
import Testing
import FolioCore
import FolioReader
@testable import FolioAudio

@Suite("Player marks")
struct SpeechMarksTests {
    private let doc = ArticleParser.parse(html: """
        <p>The first paragraph is long enough to stand on its own. It has a second sentence too.</p>
        <h2>What changed</h2>
        <p>The second paragraph follows the heading and says a little more about it.</p>
        <p>The last one closes the article.</p>
        """, title: nil)

    @Test func oneMarkPerBlockWithTheTitleAndHeadingsLabelled() {
        let options = SpeechScriptOptions(language: .english, sourceName: "The Margin", announceSource: true)
        let script = SpeechScript.build(document: doc, title: "Rising seas", options: options)
        let marks = script.marks
        // Title, paragraph, heading, paragraph, paragraph; the spoken byline has no mark.
        #expect(marks.count == 5)
        #expect(marks[0].isTitle && marks[0].fraction == 0)
        #expect(marks[2].isHeading && !marks[1].isHeading && !marks[0].isHeading)
        #expect(marks.map(\.fraction) == marks.map(\.fraction).sorted())
        #expect(marks.allSatisfy { !script.segments[$0.segment].isAnnouncement })
    }

    @Test func sentenceModeStillMarksBlocksNotSentences() {
        let options = SpeechScriptOptions(granularity: .sentence, includeTitle: false, language: .english)
        let script = SpeechScript.build(document: doc, title: nil, options: options)
        #expect(script.segments.count > script.marks.count)
        #expect(script.marks.count == 4)
    }

    @Test func dragsLandOnTheBlockStartingBeforeTheFinger() throws {
        let script = SpeechScript.build(document: doc, title: nil, options: SpeechScriptOptions(includeTitle: false, language: .english))
        let marks = script.marks
        #expect(marks.mark(at: 0)?.segment == marks[0].segment)
        #expect(marks.mark(at: -0.2)?.segment == marks[0].segment)
        #expect(marks.mark(at: 1)?.segment == marks.last?.segment)
        let between = (marks[1].fraction + marks[2].fraction) / 2
        #expect(marks.mark(at: between)?.segment == marks[1].segment)
        #expect([SpeechMark]().mark(at: 0.5) == nil)
    }

    @Test func paragraphPositionCountsTheBodyNotTheTitle() throws {
        let script = SpeechScript.build(document: doc, title: "Rising seas", options: SpeechScriptOptions(language: .english))
        let marks = script.marks
        #expect(marks.paragraph(containing: marks[0].segment) == nil)  // the headline
        let first = try #require(marks.paragraph(containing: marks[1].segment))
        #expect(first.index == 1 && first.count == 4)
        let last = try #require(marks.paragraph(containing: script.segments.count - 1))
        #expect(last.index == 4 && last.count == 4)
    }
}
