import Foundation
import Testing
@testable import ITSpendTracker

/// REQ-015: a grouping a connector does not provide is not shown; one it offers but has no rows for says "no data".
@Suite struct BreakdownGroupTests {
    @Test func offeredGroupsFollowTheConnectorCapabilities() {
        #expect(ConnectorID.cline.descriptor.capabilities.breakdownDimensions == [.account, .lineItem])  // no project
        #expect(ConnectorID.gitHub.descriptor.capabilities.breakdownDimensions == [.account, .lineItem, .project])
        #expect(ConnectorCapabilities().breakdownDimensions.isEmpty)
    }

    @Test func groupWithoutRowsIsMarkedNoDataAndUnofferedGroupIsLeftOut() {
        let groups = BreakdownGroup.groups(offered: [.lineItem, .project], counts: [.lineItem: 3])
        #expect(groups == [BreakdownGroup(dimension: .lineItem, rowCount: 3), BreakdownGroup(dimension: .project, rowCount: 0)])
        #expect(groups.map(\.hasData) == [true, false])
        // Rows of a dimension the connector does not offer (stale data) never add a group.
        #expect(BreakdownGroup.groups(offered: [.lineItem], counts: [.lineItem: 1, .account: 5]).map(\.dimension) == [.lineItem])
    }
}
