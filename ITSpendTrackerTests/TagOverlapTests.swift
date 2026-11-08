import Foundation
import Testing
@testable import ITSpendTracker

/// REQ-020: a tag's total never counts the same money twice. A tagged service covers its tagged children; otherwise
/// targets are added only when they are provably disjoint (DEC-035), and an unresolved overlap makes the whole tag's
/// total unavailable while every target keeps its own amount (DEC-034).
@Suite struct TagOverlapTests {
    private func state(_ target: TagTarget, _ name: String, _ cost: Decimal?, estimate: Bool = false) -> TagTargetState {
        TagTargetState(target: target, name: name, cost: cost, costIsEstimate: estimate)
    }

    private func assignment(_ target: TagTarget, _ tags: [String]) -> TagAssignment {
        TagAssignment(target: target, displayName: "stored", tags: tags)
    }

    private func service(_ name: String, spend: Decimal? = nil, estimate: Bool = false, present: [TagTargetState] = [],
                         tagged: [(TagTarget, [String])]) -> TagServiceInput {
        TagServiceInput(serviceName: name, spend: spend, spendIsEstimate: estimate, present: present,
                        assignments: tagged.map { assignment($0.0, $0.1) })
    }

    private func project(_ label: String) -> TagTarget { .breakdownItem(dimension: .project, label: label) }
    private func model(_ label: String) -> TagTarget { .breakdownItem(dimension: .lineItem, label: label) }

    // MARK: A tagged service covers its tagged children

    @Test func aTaggedServiceContributesOnceAndCoversItsTaggedKey() throws {
        // The example of the specification: a service of 100 and its key of 30, tagged together, contribute 100.
        let totals = TagTotal.compute([service("A", spend: 100, present: [state(.key("k1"), "Bot", 30)],
                                               tagged: [(.service, ["client"]), (.key("k1"), ["client"])])])
        let tag = try #require(totals.first)
        #expect(tag.total == 100)
        #expect(tag.members.first { $0.target == .service }?.isCounted == true)
        let key = try #require(tag.members.first { $0.target == .key("k1") })
        #expect(key.isCoveredByService && !key.isCounted && key.cost == 30) // shown with its own amount, not added
        #expect(tag.unresolvedServices.isEmpty)
    }

    @Test func aTaggedServiceCoversChildrenOfEveryKind() {
        let totals = TagTotal.compute([service("A", spend: 80,
                                               present: [state(.key("k1"), "Bot", 30), state(project("web"), "web", 40),
                                                         state(model("gpt"), "gpt", 25)],
                                               tagged: [(.service, ["t"]), (.key("k1"), ["t"]), (project("web"), ["t"]), (model("gpt"), ["t"])])])
        #expect(totals.first?.total == 80)
        #expect(totals.first?.members.filter(\.isCoveredByService).count == 3)
    }

    @Test func aTaggedServiceWithoutSpendStillCoversItsChildrenAndStaysUnavailable() throws {
        let totals = TagTotal.compute([service("A", spend: nil, present: [state(.key("k1"), "Bot", 30)],
                                               tagged: [(.service, ["t"]), (.key("k1"), ["t"])])])
        let tag = try #require(totals.first)
        #expect(tag.total == 0 && tag.hasUnavailable) // the child is inside the service, so it is not added instead
        #expect(tag.members.first { $0.target == .key("k1") }?.isCounted == false)
    }

    @Test func aTagOnlyCoversChildrenTaggedWithTheSameTag() {
        let totals = TagTotal.compute([service("A", spend: 100, present: [state(.key("k1"), "Bot", 30)],
                                               tagged: [(.service, ["whole"]), (.key("k1"), ["part"])])])
        #expect(totals.first { $0.tag == "whole" }?.total == 100)
        #expect(totals.first { $0.tag == "part" }?.total == 30) // different tags may overlap; totals are not additive
    }

    // MARK: Disjoint targets are added

    @Test func distinctKeysAreDisjointAndAdded() {
        let totals = TagTotal.compute([service("A", spend: 99, present: [state(.key("k1"), "Bot", 30), state(.key("k2"), "Cron", 12)],
                                               tagged: [(.key("k1"), ["t"]), (.key("k2"), ["t"])])])
        #expect(totals.first?.total == 42)
    }

    @Test func distinctItemsOfOneDimensionAreDisjointAndAdded() {
        let totals = TagTotal.compute([service("A", present: [state(project("web"), "web", 40), state(project("api"), "api", 25)],
                                               tagged: [(project("web"), ["t"]), (project("api"), ["t"])])])
        #expect(totals.first?.total == 65)
        #expect(totals.first?.unresolvedServices.isEmpty == true)
    }

    @Test func distinctNeonProjectsAreDisjointAndAdded() {
        let web = TagTarget.usageProject(organization: "Org", name: "web")
        let api = TagTarget.usageProject(organization: "Org", name: "api")
        let totals = TagTotal.compute([service("N", present: [state(web, "web", 3, estimate: true), state(api, "api", 2, estimate: true)],
                                               tagged: [(web, ["t"]), (api, ["t"])])])
        #expect(totals.first?.total == 5 && totals.first?.isApproximate == true)
    }

    @Test func targetsOfDifferentServicesAreAlwaysDisjoint() {
        let totals = TagTotal.compute([service("A", present: [state(.key("k1"), "Bot", 5)], tagged: [(.key("k1"), ["t"])]),
                                       service("B", present: [state(project("web"), "web", 7)], tagged: [(project("web"), ["t"])])])
        #expect(totals.first?.total == 12)
    }

    // MARK: Possible overlap makes the total unavailable

    @Test func itemsOfDifferentDimensionsMayBeTheSameMoneyAndAreUnresolved() throws {
        let totals = TagTotal.compute([service("A", present: [state(project("web"), "web", 40), state(model("gpt"), "gpt", 25)],
                                               tagged: [(project("web"), ["t"]), (model("gpt"), ["t"])])])
        let tag = try #require(totals.first)
        #expect(tag.total == nil)
        #expect(tag.unresolvedServices == ["A"])
        #expect(Set(tag.members.compactMap(\.cost)) == [40, 25]) // every target keeps its own amount
        #expect(tag.members.allSatisfy { !$0.isCounted })
    }

    @Test func aKeyAndABreakdownItemOfOneServiceAreUnresolved() {
        let totals = TagTotal.compute([service("A", present: [state(.key("k1"), "Bot", 30), state(project("web"), "web", 40)],
                                               tagged: [(.key("k1"), ["t"]), (project("web"), ["t"])])])
        #expect(totals.first?.total == nil)
        #expect(totals.first?.unresolvedServices == ["A"])
    }

    @Test func oneUnresolvedServiceMakesTheWholeTagUnavailableButNamesIt() throws {
        let totals = TagTotal.compute([
            service("A", present: [state(.key("k1"), "Bot", 3), state(.key("k2"), "Cron", 2)], tagged: [(.key("k1"), ["t"]), (.key("k2"), ["t"])]),
            service("B", present: [state(.key("k9"), "Job", 30), state(project("web"), "web", 40)],
                    tagged: [(.key("k9"), ["t"]), (project("web"), ["t"])]),
        ])
        let tag = try #require(totals.first)
        #expect(tag.total == nil)
        #expect(tag.unresolvedServices == ["B"])
        #expect(tag.members.filter { $0.serviceName == "A" }.allSatisfy { $0.isCounted }) // the resolved part is still known
    }

    @Test func taggingTheServiceItselfResolvesTheOverlap() {
        let totals = TagTotal.compute([service("B", spend: 90, present: [state(.key("k9"), "Job", 30), state(project("web"), "web", 40)],
                                               tagged: [(.service, ["t"]), (.key("k9"), ["t"]), (project("web"), ["t"])])])
        #expect(totals.first?.total == 90)
        #expect(totals.first?.unresolvedServices.isEmpty == true)
    }

    @Test func aTargetWithoutACostTakesNoPartInTheOverlapCheck() {
        let totals = TagTotal.compute([service("A", present: [state(.key("k1"), "Bot", 30), state(project("web"), "web", nil)],
                                               tagged: [(.key("k1"), ["t"]), (project("web"), ["t"])])])
        #expect(totals.first?.total == 30)
        #expect(totals.first?.hasUnavailable == true)
    }

    @Test func aMissingTargetTakesNoPartInTheOverlapCheck() {
        let totals = TagTotal.compute([service("A", present: [state(.key("k1"), "Bot", 30)],
                                               tagged: [(.key("k1"), ["t"]), (project("gone"), ["t"])])])
        #expect(totals.first?.total == 30)
    }

    @Test func unresolvedTagsSortAfterResolvedOnes() {
        let totals = TagTotal.compute([service("A", present: [state(.key("k1"), "Bot", 1), state(project("web"), "web", 500), state(model("gpt"), "gpt", 400)],
                                               tagged: [(.key("k1"), ["small"]), (project("web"), ["mixed"]), (model("gpt"), ["mixed"])])])
        #expect(totals.map(\.tag) == ["small", "mixed"])
    }

    // MARK: Estimates

    @Test func aCoveredEstimateDoesNotMakeTheTotalApproximate() {
        let totals = TagTotal.compute([service("A", spend: 100, present: [state(.key("k1"), "Bot", 30, estimate: true)],
                                               tagged: [(.service, ["t"]), (.key("k1"), ["t"])])])
        #expect(totals.first?.total == 100 && totals.first?.isApproximate == false)
        let estimated = TagTotal.compute([service("A", spend: 100, estimate: true, tagged: [(.service, ["t"])])])
        #expect(estimated.first?.isApproximate == true)
    }

    // MARK: Where a row opens (REQ-019)

    @Test func eachRowOpensItsOwnPageOrSectionAndAMissingTargetOpensItsService() {
        let totals = TagTotal.compute([service("A", spend: 5,
                                               present: [state(.key("k1"), "Bot", 1), state(project("web"), "web", 2),
                                                         state(.usageProject(organization: "Org", name: "api"), "api", 3)],
                                               tagged: [(.service, ["t"]), (.key("k1"), ["t"]), (project("web"), ["t"]),
                                                        (.usageProject(organization: "Org", name: "api"), ["t"]),
                                                        (.key("gone"), ["t"]), (project("gone"), ["t"])])])
        let destinations = Dictionary(uniqueKeysWithValues: (totals.first?.members ?? []).map { ($0.target, $0.destination) })
        #expect(destinations[.service] == .service)
        #expect(destinations[.key("k1")] == .key("k1"))
        #expect(destinations[project("web")] == .breakdownSection)
        #expect(destinations[.usageProject(organization: "Org", name: "api")] == .usageSection)
        #expect(destinations[.key("gone")] == .service) // missing: no page of its own
        #expect(destinations[project("gone")] == .service)
    }
}
