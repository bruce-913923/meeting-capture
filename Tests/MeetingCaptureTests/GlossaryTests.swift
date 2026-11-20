import XCTest
@testable import MeetingCapture

/// 2026-11-20 的問題：空白也被當成錯字的分隔，「麥肯 c」拆出一個「c」，逐字稿裡英文的 c 全被換成「麥肯錫」（sync → syn麥肯錫）；
/// 「human inner loop」拆成 human／inner／loop，把轉對的「human in the loop」改成「human in the human in the loop in the human in the loop」。
final class GlossaryTests: XCTestCase {
    let list = """
    # 人名
    曉銘 <- 曉明
    # 其他
    減和、簡和、簡合 > 檢核
    human inner loop > human in the loop
    cloud code > Claude Code
    AI boom > AI Board
    麥肯 c > 麥肯錫
    """

    func testSpacesStayInsideAWrongWord() {
        XCTAssertEqual(Glossary.parse("human inner loop > human in the loop").0, ["human inner loop"])
        XCTAssertEqual(Glossary.parse("麥肯 c > 麥肯錫").0, ["麥肯 c"])
        XCTAssertEqual(Glossary.parse("減和、簡和, 簡合 > 檢核").0, ["減和", "簡和", "簡合"])
        XCTAssertFalse(Glossary(list).fixes.contains { $0.wrong == "c" || $0.wrong == "AI" || $0.wrong == "code" })
    }

    func testBackwardArrow() {
        let (wrongs, right) = Glossary.parse("曉銘 <- 曉明")
        XCTAssertEqual(wrongs, ["曉明"])
        XCTAssertEqual(right, "曉銘")
        XCTAssertEqual(Glossary(list).pinned, ["曉銘"])
    }

    func testEnglishInsideOtherWordsIsLeftAlone() {
        let text = "這件事要跟團隊 sync，它能 cover 嗎？先 check 一下 code，AI 很好用，麥肯 cover 不算"
        XCTAssertEqual(Glossary(list).apply(text).0, text)
    }

    func testTextThatIsAlreadyRightIsLeftAlone() {
        let g = Glossary(list)
        XCTAssertEqual(g.apply("直接改 human in the loop").0, "直接改 human in the loop")
        XCTAssertEqual(Glossary("麥肯 > 麥肯錫").apply("麥肯錫的風格").0, "麥肯錫的風格")
        XCTAssertTrue(g.apply("直接改 human in the loop").1.isEmpty)
    }

    func testPhrasesAreReplaced() {
        let (out, counts) = Glossary(list).apply("麥肯 c 的風格、麥肯c 風格、human inner loop、Cloud Code、ai boom、曉明說要減和")
        XCTAssertEqual(out, "麥肯錫 的風格、麥肯錫 風格、human in the loop、Claude Code、AI Board、曉銘說要檢核")
        XCTAssertEqual(counts["麥肯錫"], 2)
        XCTAssertEqual(counts["Claude Code"], 1)
    }

    func testReplacedTextIsNotReplacedAgain() {
        // 一次比對完才換：第一條換上去的字，不會再被第二條換掉
        let g = Glossary("cloud code > Claude Code\nClaude > 克勞德")
        XCTAssertEqual(g.apply("開 cloud code").0, "開 Claude Code")
    }

    func testAddingKeepsPhrases() {
        let text = Glossary.adding("麥肯 c > 麥肯錫", wrong: "麥肯西", right: "麥肯錫", kind: "其他")
        XCTAssertEqual(text, "麥肯 c、麥肯西 > 麥肯錫")
    }
}
