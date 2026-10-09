import XCTest
@testable import MarkdownCore

final class PerformanceTests: XCTestCase {
    static let sample: String = {
        let chunk = """
        # Heading with **bold** and `code`

        A paragraph with *emphasis*, ~~strike~~, a [link](https://example.com/path) and an escape \\*.
        Another line with 👋🏽 emoji and **nested *emphasis* inside** it.

        - bullet item with `code`
          - nested item [ref](x)
        1. ordered item
        - [ ] task item
        > quote with **bold**

        ```swift
        let value = compute(**not bold**)
        ```
        ---

        | Model | Job | Notes |
        |:------|:---:|------:|
        | **Opus** | Plans and reviews | `x \\| y` |
        | Sonnet | Executes the plan | 2 |
        Haiku | Fast | 3

        """
        var s = ""
        while s.utf16.count < 200_000 { s += chunk }
        return s
    }()

    /// The per-keystroke cost is the block parse (`MarkdownDocument.init`); inlines are parsed lazily,
    /// only for the blocks being restyled. Guard both: blocks < 20 ms, every block's inlines < 60 ms
    /// (debug build, which runs ~3x slower than release).
    func testParse200KB() {
        let text = Self.sample
        func fullParse() -> Int {
            let doc = MarkdownDocument(text)
            var count = 0
            for block in doc.blocks { count += doc.inlines(in: block).count }
            return count
        }
        _ = fullParse()  // warm up
        var best = Double.infinity
        for _ in 0..<5 {
            let start = Date()
            _ = fullParse()
            best = min(best, Date().timeIntervalSince(start))
        }
        var blocksOnly = Double.infinity
        for _ in 0..<5 {
            let start = Date()
            _ = MarkdownDocument(text).blocks.count
            blocksOnly = min(blocksOnly, Date().timeIntervalSince(start))
        }
        print("blocks-only 200KB best of 5: \(String(format: "%.2f", blocksOnly * 1000)) ms")
        print("parse 200KB best of 5: \(String(format: "%.2f", best * 1000)) ms")
        XCTAssertLessThan(blocksOnly, 0.020)
        XCTAssertLessThan(best, 0.060)
    }

    func testParseMeasure() {
        let text = Self.sample
        measure { _ = MarkdownDocument(text).blocks.count }
    }
}
