import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Document outline")
struct MarkdownDocumentOutlineTests {
    @Test("headings preserve UTF-16 positions and ignore fenced code")
    func outline() {
        let source = "# 开始\n正文\n```md\n## not a heading\n```\n### 结尾 ###\n"
        let items = MarkdownDocumentOutline.parse(source)
        #expect(items.map(\.level) == [1, 3])
        #expect(items.map(\.title) == ["开始", "结尾"])
        #expect(items[0].sourceRange.location == 0)
        #expect(items[1].sourceRange.location == (source as NSString).range(of: "### 结尾").location)
    }
}
