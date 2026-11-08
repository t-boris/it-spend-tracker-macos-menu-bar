import AppKit
import SwiftUI
import Testing
@testable import ITSpendTracker

/// REQ-014: charts grow with the window. A probe with the chart-height modifier is hosted in an off-screen window of a
/// given height, inside the same kinds of container the pages use, and its laid-out height is measured.
@MainActor
@Suite struct ChartGrowthTests {
    private struct HeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    private final class Box: @unchecked Sendable { var height: CGFloat = 0 }

    private func probeHeight(windowHeight: CGFloat, in container: (AnyView) -> AnyView) -> CGFloat {
        let box = Box()
        let probe = Color.clear
            .growingChartHeight(minimum: 260, fraction: 0.40)
            .background(GeometryReader { proxy in Color.clear.preference(key: HeightKey.self, value: proxy.size.height) })
            .onPreferenceChange(HeightKey.self) { box.height = $0 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: windowHeight),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: container(AnyView(probe)))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: windowHeight)
        window.contentView = host
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return box.height
    }

    private func inScrollView(_ content: AnyView) -> AnyView { AnyView(ScrollView { content }) }

    private func inGroupedForm(_ content: AnyView) -> AnyView {
        AnyView(Form { Section("History") { content } }.formStyle(.grouped))
    }

    @Test func chartInAScrollViewGrowsWithTheWindow() {
        let small = probeHeight(windowHeight: 560, in: inScrollView)
        let large = probeHeight(windowHeight: 1000, in: inScrollView)
        #expect(small == 260)             // the minimum holds in a small window
        #expect(large > small + 100)      // and the chart is taller in a tall window (0.40 of 1000 = 400)
    }

    @Test func chartInAGroupedFormGrowsWithTheWindow() {
        let small = probeHeight(windowHeight: 560, in: inGroupedForm)
        let large = probeHeight(windowHeight: 1000, in: inGroupedForm)
        #expect(small >= 260)
        #expect(large > small + 100)
    }
}
