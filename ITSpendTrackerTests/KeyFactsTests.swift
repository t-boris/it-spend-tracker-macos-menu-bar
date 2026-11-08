import Foundation
import Testing
@testable import ITSpendTracker

/// REQ-016: facts the provider does not report show "unavailable"; they are never omitted.
@Suite struct KeyFactsTests {
    @Test func aKeyWithNoProviderFactsHasEveryFactUnavailable() {
        let facts = KeyFacts(hint: nil, status: nil, details: [])
        #expect(facts.unavailable == [.project, .maskedValue, .owner, .status, .scopes])
        #expect(facts.rows.map(\.field) == [.project, .maskedValue, .owner, .status, .scopes])  // fixed display order
    }

    @Test func emptyStringsCountAsUnavailableNotAsValues() {
        #expect(KeyFacts(hint: "", status: "", details: []).unavailable.contains(.maskedValue))
        #expect(KeyFacts(hint: "", status: "", details: []).unavailable.contains(.status))
    }

    @Test func reportedFactsAreAvailable() {
        let details = [KeyDetail(kind: .project, value: "Example"), KeyDetail(kind: .createdBy, value: "Alex"),
                       KeyDetail(kind: .scopes, value: "any API")]
        let facts = KeyFacts(hint: "sk-…abcd", status: "active", details: details)
        #expect(facts.unavailable.isEmpty)
        #expect(facts.rows.first { $0.field == .owner }?.details.map(\.value) == ["Alex"])  // createdBy counts as the owner fact
    }

    @Test func onlyTheMissingFactsAreUnavailable() {
        // A Google-style key: project and scopes reported, no owner or status.
        let facts = KeyFacts(hint: "my-project", status: nil,
                             details: [KeyDetail(kind: .project, value: "my-project"), KeyDetail(kind: .scopes, value: "Maps")])
        #expect(facts.unavailable == [.owner, .status])
    }
}
