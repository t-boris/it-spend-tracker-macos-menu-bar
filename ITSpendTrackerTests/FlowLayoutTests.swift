import CoreGraphics
import Testing
@testable import ITSpendTracker

/// Tag chips wrap onto further lines instead of being squeezed until their text breaks.
@Suite struct FlowLayoutTests {
    private func sizes(_ widths: [CGFloat], height: CGFloat = 20) -> [CGSize] { widths.map { CGSize(width: $0, height: height) } }

    @Test func chipsThatFitStayOnOneLine() {
        let result = FlowLayout.arrange(sizes([50, 40, 30]), maxWidth: 200, spacing: 6)
        #expect(result.offsets == [CGPoint(x: 0, y: 0), CGPoint(x: 56, y: 0), CGPoint(x: 102, y: 0)])
        #expect(result.size == CGSize(width: 132, height: 20))
    }

    @Test func aChipThatDoesNotFitStartsTheNextLine() {
        let result = FlowLayout.arrange(sizes([50, 50, 50]), maxWidth: 120, spacing: 6)
        #expect(result.offsets == [CGPoint(x: 0, y: 0), CGPoint(x: 56, y: 0), CGPoint(x: 0, y: 26)])
        #expect(result.size == CGSize(width: 106, height: 46))
    }

    @Test func aChipExactlyAsWideAsTheLineStillFits() {
        let result = FlowLayout.arrange(sizes([50, 50]), maxWidth: 106, spacing: 6)
        #expect(result.offsets.map(\.y) == [0, 0])
    }

    @Test func aChipWiderThanTheLineGetsALineOfItsOwn() {
        let result = FlowLayout.arrange(sizes([30, 200, 30]), maxWidth: 100, spacing: 6)
        #expect(result.offsets == [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 26), CGPoint(x: 0, y: 52)])
        #expect(result.size.width == 200)
    }

    @Test func aLineIsAsTallAsItsTallestChip() {
        let result = FlowLayout.arrange([CGSize(width: 40, height: 20), CGSize(width: 40, height: 30), CGSize(width: 40, height: 20)],
                                        maxWidth: 90, spacing: 4)
        #expect(result.offsets[2] == CGPoint(x: 0, y: 34)) // third chip below the 30-high line
        #expect(result.size.height == 54)
    }

    @Test func nothingToPlaceTakesNoSpace() {
        #expect(FlowLayout.arrange([], maxWidth: 100, spacing: 6).size == .zero)
    }

    @Test func withoutAWidthLimitEverythingStaysOnOneLine() {
        let result = FlowLayout.arrange(sizes([500, 500, 500]), maxWidth: .infinity, spacing: 6)
        #expect(result.offsets.allSatisfy { $0.y == 0 })
    }
}
