import Testing
@testable import ITSpendTracker

@Suite struct ServiceSectionsTests {
    /// Regression (REQ-003, REQ-013): Neon's keys were fetched and stored but never listed, so they could not be tagged.
    @Test func usageMetricsServiceStillListsItsKeys() {
        let neon = ServiceSections(isConnected: true,
                                   hasUsageMetrics: ConnectorID.neon.descriptor.capabilities.usageMetrics)
        #expect(neon == ServiceSections(isConnected: true, hasUsageMetrics: true))
        #expect(neon.usageMetrics && neon.keys)
        #expect(!neon.breakdown && !neon.tokens)  // its metrics replace the money breakdown and tokens
    }

    @Test func ordinaryConnectedServiceShowsBreakdownKeysAndTokens() {
        let vercel = ServiceSections(isConnected: true,
                                     hasUsageMetrics: ConnectorID.vercel.descriptor.capabilities.usageMetrics)
        #expect(!vercel.usageMetrics)
        #expect(vercel.breakdown && vercel.keys && vercel.tokens)
    }

    @Test func manualServiceShowsNone() {
        let manual = ServiceSections(isConnected: false, hasUsageMetrics: false)
        #expect(!manual.usageMetrics && !manual.breakdown && !manual.keys && !manual.tokens)
    }
}
