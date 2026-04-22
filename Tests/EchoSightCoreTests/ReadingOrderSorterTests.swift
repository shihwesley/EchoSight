import Testing
import Foundation
@testable import EchoSightCore

// MARK: - ReadingOrderSorterTests
//
// ReadingOrderSorter operates on RawTextObservation (a Sendable value type),
// not directly on VNRecognizedTextObservation. This allows full unit testing
// without requiring Vision framework internals.
//
// Vision coordinate space:
// - Origin: bottom-left
// - Y increases upward (higher minY = closer to top of image)

@Suite("ReadingOrderSorter")
struct ReadingOrderSorterTests {

    // MARK: - Helpers

    private func obs(text: String, x: CGFloat, y: CGFloat, width: CGFloat = 0.1, height: CGFloat = 0.05) -> RawTextObservation {
        RawTextObservation(
            text: text,
            confidence: 0.9,
            // Vision: boundingBox.minY is bottom of the glyph; higher = closer to top of image.
            boundingBox: CGRect(x: x, y: y, width: width, height: height)
        )
    }

    // MARK: - Default Threshold

    @Test("default band threshold is 0.05")
    func defaultBandThreshold() {
        #expect(ReadingOrderSorter.bandThreshold == 0.05)
    }

    // MARK: - Empty / Single

    @Test("empty input returns empty array")
    func emptyInput() {
        let result = ReadingOrderSorter.sort([])
        #expect(result.isEmpty)
    }

    @Test("single observation returns the same observation")
    func singleObservation() {
        let single = obs(text: "hello", x: 0.1, y: 0.5)
        let result = ReadingOrderSorter.sort([single])
        #expect(result.count == 1)
        #expect(result[0].text == "hello")
    }

    // MARK: - Row Ordering (Top to Bottom)

    @Test("two rows: higher Y (top of image) comes first")
    func topRowFirst() {
        let topRow = obs(text: "top", x: 0.1, y: 0.8)    // Higher Y = top of image
        let bottomRow = obs(text: "bottom", x: 0.1, y: 0.2)  // Lower Y = bottom of image
        let result = ReadingOrderSorter.sort([bottomRow, topRow])
        #expect(result[0].text == "top")
        #expect(result[1].text == "bottom")
    }

    // MARK: - Left-to-Right Within Row

    @Test("same row: left word comes before right word")
    func leftToRightInRow() {
        // Same Y band (within 0.05)
        let left = obs(text: "left", x: 0.1, y: 0.5)
        let right = obs(text: "right", x: 0.6, y: 0.5)
        let result = ReadingOrderSorter.sort([right, left])
        #expect(result[0].text == "left")
        #expect(result[1].text == "right")
    }

    // MARK: - Multi-Row Sign

    @Test("three words in a column read top-to-bottom")
    func columnTopToBottom() {
        let line1 = obs(text: "EXIT", x: 0.3, y: 0.9)
        let line2 = obs(text: "→", x: 0.3, y: 0.75)
        let line3 = obs(text: "Emergency", x: 0.1, y: 0.6)
        let result = ReadingOrderSorter.sort([line3, line1, line2])
        #expect(result[0].text == "EXIT")
        #expect(result[1].text == "→")
        #expect(result[2].text == "Emergency")
    }

    // MARK: - Two-Column Layout

    @Test("two-column layout reads left column first then right column")
    func twoColumnLayout() {
        // Left column: two rows
        let leftTop = obs(text: "L-top", x: 0.05, y: 0.9)
        let leftBottom = obs(text: "L-bot", x: 0.05, y: 0.4)
        // Right column: two rows
        let rightTop = obs(text: "R-top", x: 0.55, y: 0.9)
        let rightBottom = obs(text: "R-bot", x: 0.55, y: 0.4)

        let result = ReadingOrderSorter.sort([rightBottom, leftBottom, rightTop, leftTop])

        // Top band: left word before right word
        let topBandTexts = result.filter { $0.boundingBox.minY > 0.7 }.map { $0.text }
        #expect(topBandTexts.contains("L-top"))
        #expect(topBandTexts.contains("R-top"))
        let leftIndex = result.firstIndex(where: { $0.text == "L-top" }) ?? Int.max
        let rightIndex = result.firstIndex(where: { $0.text == "R-top" }) ?? Int.max
        #expect(leftIndex < rightIndex)
    }

    // MARK: - Band Threshold

    @Test("observations within band threshold are grouped into same row")
    func bandGrouping() {
        // Y values differ by 0.03 < default threshold 0.05 → same band
        let a = obs(text: "a", x: 0.1, y: 0.50)
        let b = obs(text: "b", x: 0.4, y: 0.52)
        let result = ReadingOrderSorter.sort([b, a])
        // Both in same band → sorted left-to-right
        #expect(result[0].text == "a") // minX 0.1 < 0.4
        #expect(result[1].text == "b")
    }

    @Test("observations outside band threshold are in different rows")
    func separateBands() {
        // Y values differ by 0.08 > default threshold 0.05 → different bands
        let top = obs(text: "top", x: 0.5, y: 0.80)
        let bot = obs(text: "bot", x: 0.1, y: 0.72)
        let result = ReadingOrderSorter.sort([bot, top])
        // Different bands → top (higher Y) first, regardless of X
        #expect(result[0].text == "top")
        #expect(result[1].text == "bot")
    }
}
