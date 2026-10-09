import XCTest
@testable import MarkdownCore

/// GFM pipe tables (research/gfm-table-spec.md; every expectation matches cmark-gfm 0.29.0.gfm.13
/// except where noted).
final class TableScannerTests: XCTestCase {
    private func kinds(_ text: String) -> [BlockKind] { BlockScanner.scan(text).map(\.kind) }
    private func cells(_ text: String, _ row: TableRow) -> [String] {
        row.cells.map { (text as NSString).substring(with: $0) }
    }
    private func table(_ text: String, at index: Int = 0) -> (Block, TableLayout) {
        let blocks = BlockScanner.scan(text).filter { if case .table = $0.kind { return true } else { return false } }
        let block = blocks[index]
        return (block, block.table!)
    }

    func testPlainTable() {
        let text = "| Model | Job |\n|---|---|\n| Opus | Plans |\n| Sonnet | Executes |\n"
        XCTAssertEqual(kinds(text), [.table(alignments: [.none, .none])])
        let (block, t) = table(text)
        XCTAssertEqual(block.range, NSRange(location: 0, length: (text as NSString).length))
        XCTAssertEqual(t.columns, 2)
        XCTAssertEqual(cells(text, t.header), ["Model", "Job"])
        XCTAssertEqual(t.body.map { cells(text, $0) }, [["Opus", "Plans"], ["Sonnet", "Executes"]])
        XCTAssertEqual(t.header.pipes, [0, 8, 14])
        XCTAssertEqual(t.delimiter.line, NSRange(location: 16, length: 9))
        // Markers: every pipe plus the whole delimiter row.
        XCTAssertTrue(block.markerRanges.contains(NSRange(location: 16, length: 9)))
        XCTAssertTrue(block.markerRanges.contains(NSRange(location: 8, length: 1)))
        XCTAssertEqual(block.markerRanges.count, 3 + 1 + 3 + 3)
    }

    func testAlignment() {
        let text = "| a | b | c | d |\n|:--|:-:|--:|---|\n| 1 | 2 | 3 | 4 |\n"
        XCTAssertEqual(kinds(text), [.table(alignments: [.left, .center, .right, .none])])
        // One hyphen is enough; spaces and tabs around markers are fine.
        XCTAssertEqual(kinds("|x|\n|-|\n"), [.table(alignments: [.none])])
        XCTAssertEqual(kinds("| a | b |\n|\t:---\t| ---: |   \n"), [.table(alignments: [.left, .right])])
    }

    func testEscapedPipeStaysInCell() {
        let text = "| f\\|oo | x |\n| --- | --- |\n| `a \\| b` | y |\n"
        let (_, t) = table(text)
        XCTAssertEqual(cells(text, t.header), ["f\\|oo", "x"])
        XCTAssertEqual(cells(text, t.body[0]), ["`a \\| b`", "y"])
        XCTAssertEqual(t.header.pipes.count, 3)
        // An escaped backslash does not escape the pipe after it (CommonMark reading; cmark-gfm #277 differs).
        let (_, t2) = table("| a | b |\n|---|---|\n| B \\\\| x |\n")
        XCTAssertEqual(t2.body[0].cells.count, 2)
    }

    func testNoLeadingOrTrailingPipe() {
        let text = "Name | Score\n--- | ---\nAnn | 10\n"
        XCTAssertEqual(kinds(text), [.table(alignments: [.none, .none])])
        let (_, t) = table(text)
        XCTAssertEqual(cells(text, t.header), ["Name", "Score"])
        XCTAssertEqual(t.header.pipes, [5])
        XCTAssertEqual(cells(text, t.body[0]), ["Ann", "10"])
        // Inconsistent outer pipes across rows are fine (GFM Example 199).
        XCTAssertEqual(kinds("| a | b |\n:-: | --:\nc | d |\n"), [.table(alignments: [.center, .right])])
    }

    func testUnevenRows() {
        let text = "| A | B | C |\n|---|---|---|\n| 1 | 2 |\n| 1 | 2 | 3 | 4 |\n"
        let (_, t) = table(text)
        XCTAssertEqual(t.columns, 3)
        XCTAssertEqual(cells(text, t.body[0]), ["1", "2"])            // padded for layout
        XCTAssertEqual(cells(text, t.body[1]), ["1", "2", "3", "4"])  // extra cell kept, not a column
        // Empty cells.
        let s = "|| a |\n|-|-|\n| d || e |\n"
        let (_, t2) = table(s)
        XCTAssertEqual(cells(s, t2.header), ["", "a"])
        XCTAssertEqual(cells(s, t2.body[0]), ["d", "", "e"])
    }

    func testCellCountMismatchIsParagraph() {
        XCTAssertEqual(kinds("| abc | def |\n| --- |\n| bar |\n"), [.paragraph, .paragraph, .paragraph])
        XCTAssertEqual(kinds("| a | b |\n| - | - | - |\n"), [.paragraph, .paragraph])
        XCTAssertEqual(kinds("| a | b | junk\n| - | - |\n"), [.paragraph, .paragraph])
    }

    func testInvalidDelimiterRows() {
        XCTAssertEqual(kinds("| a | b |\n| - | - | x\n"), [.paragraph, .paragraph])
        XCTAssertEqual(kinds("| a |\n| : |\n"), [.paragraph, .paragraph])
        XCTAssertEqual(kinds("| a |\n| - - |\n"), [.paragraph, .paragraph])
        XCTAssertEqual(kinds("    | a |\n    | - |\n"), [.paragraph, .paragraph])
    }

    func testTerminatedByBlankLine() {
        XCTAssertEqual(kinds("| a |\n| - |\n| b |\n\nafter\n"), [.table(alignments: [.none]), .blank, .paragraph])
        XCTAssertEqual(kinds("| a |\n| - |\n   \nafter\n"), [.table(alignments: [.none]), .blank, .paragraph])
    }

    func testTerminatedByOtherBlocks() {
        let head = "| a | b |\n|---|---|\n| c | d |\n"
        XCTAssertEqual(kinds(head + "# h\n"), [.table(alignments: [.none, .none]), .heading(level: 1)])
        XCTAssertEqual(kinds(head + "- item\n"), [.table(alignments: [.none, .none]), .bulletItem(depth: 0)])
        XCTAssertEqual(kinds(head + "1. one\n"), [.table(alignments: [.none, .none]), .orderedItem(depth: 0)])
        XCTAssertEqual(kinds(head + "> q\n"), [.table(alignments: [.none, .none]), .blockquote])
        XCTAssertEqual(kinds(head + "---\n"), [.table(alignments: [.none, .none]), .horizontalRule])
        XCTAssertEqual(kinds(head + "```\ncode\n```\n"), [.table(alignments: [.none, .none]), .fencedCode(language: nil)])
        XCTAssertEqual(kinds(head + "    | e | f |\n"), [.table(alignments: [.none, .none]), .paragraph])
    }

    func testPipelessLineContinuesTable() {
        let text = "| a | b |\n|---|---|\nbar\n\nbar\n"
        XCTAssertEqual(kinds(text), [.table(alignments: [.none, .none]), .blank, .paragraph])
        let (_, t) = table(text)
        XCTAssertEqual(cells(text, t.body[0]), ["bar"])
        // A second header/delimiter pair without a blank line is two more rows.
        XCTAssertEqual(table("| a |\n| - |\n| b |\n| - |\n").1.body.count, 2)
    }

    func testDashSpacePipeIsAListItem() {
        XCTAssertEqual(kinds("a | b\n- | -\n1 | 2\n"), [.paragraph, .bulletItem(depth: 0), .paragraph])
        XCTAssertEqual(kinds("a | b\n-|-\n1 | 2\n"), [.table(alignments: [.none, .none])])
    }

    func testPipeRowOverDashesStaysRule() {
        XCTAssertEqual(kinds("| a |\n---\n"), [.paragraph, .horizontalRule])
        XCTAssertEqual(kinds("| a |\n--\n"), [.paragraph, .paragraph])
        XCTAssertEqual(kinds("| a |\n--- |\n"), [.table(alignments: [.none])])
    }

    func testTableInterruptsParagraph() {
        let text = "p1\np2\n| a | b |\n| - | - |\n| c | d |\n"
        XCTAssertEqual(kinds(text), [.paragraph, .paragraph, .table(alignments: [.none, .none])])
        let (block, _) = table(text)
        XCTAssertEqual(block.range.location, 6)
        // Only a paragraph line can be a header.
        XCTAssertEqual(kinds("# a | b\n|---|---|\n"), [.heading(level: 1), .paragraph])
        XCTAssertEqual(kinds("- a | b\n|---|---|\n"), [.bulletItem(depth: 0), .paragraph])
    }

    func testCRLF() {
        let text = "| a | b |\r\n|---|---|\r\n| c | d |\r\n\r\nafter"
        let blocks = BlockScanner.scan(text)
        XCTAssertEqual(blocks.map(\.kind), [.table(alignments: [.none, .none]), .blank, .paragraph])
        let t = blocks[0].table!
        XCTAssertEqual(t.header.line, NSRange(location: 0, length: 9))
        XCTAssertEqual(t.delimiter.line, NSRange(location: 11, length: 9))
        XCTAssertEqual(cells(text, t.body[0]), ["c", "d"])
        XCTAssertEqual(blocks[0].range, NSRange(location: 0, length: 33))
    }

    func testTableAtEndWithoutNewline() {
        let text = "| a | b |\n|---|---|\n| c | d |"
        let blocks = BlockScanner.scan(text)
        XCTAssertEqual(blocks.map(\.kind), [.table(alignments: [.none, .none])])
        XCTAssertEqual(blocks[0].range, NSRange(location: 0, length: (text as NSString).length))
        XCTAssertEqual(cells(text, blocks[0].table!.body[0]), ["c", "d"])
        // Header + delimiter only, at EOF.
        XCTAssertEqual(kinds("| a |\n| - |"), [.table(alignments: [.none])])
        let doc = MarkdownDocument(text)
        XCTAssertEqual(doc.blockIndex(containing: (text as NSString).length), 0)
    }

    func testInlinesArePerCell() {
        let text = "| **a | b** | `c` |\n|---|---|---|\n| *x* | y | z |\n"
        let doc = MarkdownDocument(text)
        let inlines = doc.inlines(in: doc.blocks[0])
        // `**` does not pair across the pipe; the code span and the emphasis in their own cells do.
        XCTAssertFalse(inlines.contains { $0.kind == .strong })
        XCTAssertTrue(inlines.contains { $0.kind == .code })
        XCTAssertTrue(inlines.contains { $0.kind == .emphasis })
    }

    func testShiftedTableBlockMatchesReparse() {
        let a = BlockScanner.scan("x\n| a |\n| - |\n")
        let b = BlockScanner.scan("xyz\n| a |\n| - |\n")
        XCTAssertEqual(a[1].shifted(by: 2), b[1])
    }
}
