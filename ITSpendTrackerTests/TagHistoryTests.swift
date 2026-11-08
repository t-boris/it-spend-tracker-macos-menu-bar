import Foundation
import Testing
@testable import ITSpendTracker

/// REQ-023, REQ-024, DEC-042: the spend of a tag per month. Every month follows the rules of the current month, a tag
/// applies to the whole history, and "unavailable", "no data" and zero stay apart.
@Suite struct TagHistoryTests {
    private let october = Month(year: 2026, month: 10)
    private let november = Month(year: 2026, month: 11)
    private let september = Month(year: 2026, month: 9)

    private func state(_ target: TagTarget, _ name: String, _ cost: Decimal?, estimate: Bool = false) -> TagTargetState {
        TagTargetState(target: target, name: name, cost: cost, costIsEstimate: estimate)
    }

    private func service(_ name: String, spend: Decimal? = nil, estimate: Bool = false, present: [TagTargetState] = [],
                         tagged: [(TagTarget, [String])]) -> TagServiceInput {
        TagServiceInput(serviceName: name, spend: spend, spendIsEstimate: estimate, present: present,
                        assignments: tagged.map { TagAssignment(target: $0.0, displayName: "stored", tags: $0.1) })
    }

    private func project(_ label: String) -> TagTarget { .breakdownItem(dimension: .project, label: label) }
    private func model(_ label: String) -> TagTarget { .breakdownItem(dimension: .lineItem, label: label) }

    // MARK: Months

    @Test func theRangeIsTwelveMonthsOldestFirstEndingWithTheCurrentOne() {
        let months = TagHistory.months(endingAt: november)
        #expect(months.count == 12)
        #expect(months.first == Month(year: 2025, month: 12))
        #expect(months.last == november)
        #expect(months == months.sorted())
    }

    @Test func everyTagHasOnePointForEveryMonthAsked() throws {
        let history = TagHistory.compute(months: [september, october, november]) { _ in
            [service("A", spend: 10, tagged: [(.service, ["web"])])]
        }
        let tag = try #require(history.first)
        #expect(tag.points.map(\.month) == [september, october, november])
    }

    // MARK: Each month uses its own data, a tag applies to the whole history

    @Test func eachMonthUsesItsOwnAmountsAndTheTagAppliesToAllOfThem() throws {
        let spend: [Month: Decimal] = [september: 5, october: 7, november: 11]
        let history = TagHistory.compute(months: [september, october, november]) { month in
            [service("A", spend: spend[month], present: [state(.key("k1"), "Bot", 1)], tagged: [(.key("k1"), ["web"])])]
        }
        let tag = try #require(history.first)
        // Tagged once, counted in every month with its own cost: nothing is taken from another month.
        #expect(tag.points.map(\.total) == [1, 1, 1])
        let byService = TagHistory.compute(months: [september, october, november]) { month in
            [service("A", spend: spend[month], tagged: [(.service, ["web"])])]
        }
        #expect(byService.first?.points.map(\.total) == [5, 7, 11])
    }

    @Test func aMonthWithoutDataForAServiceIsNoDataAndNotZero() throws {
        let history = TagHistory.compute(months: [september, october]) { month in
            [service("A", spend: month == october ? 0 : nil, tagged: [(.service, ["web"])])]
        }
        let points = try #require(history.first).points
        #expect(points[0].state == .noData && points[0].total == nil)
        #expect(points[1].state == .amount && points[1].total == 0) // a real zero
    }

    // MARK: The rules of the current month hold in every month

    @Test func anUnresolvedOverlapMakesOnlyThatMonthUnavailable() throws {
        let history = TagHistory.compute(months: [september, october]) { month in
            // In October the service also has an item of another dimension: key and item may be the same money.
            let items = month == october ? [state(.key("k1"), "Bot", 30), state(project("web"), "web", 40)]
                                         : [state(.key("k1"), "Bot", 30)]
            return [service("A", present: items, tagged: [(.key("k1"), ["t"]), (project("web"), ["t"])])]
        }
        let points = try #require(history.first).points
        #expect(points[0].state == .amount && points[0].total == 30)
        #expect(points[1].state == .unavailable && points[1].total == nil)
        #expect(points[1].unresolvedServices == ["A"])
        #expect(points[1].services.isEmpty) // nothing of service A is counted, so nothing is attributed to it
    }

    @Test func aTaggedServiceStillCoversItsTaggedKeyInEveryMonth() throws {
        let history = TagHistory.compute(months: [september, october]) { _ in
            [service("A", spend: 100, present: [state(.key("k1"), "Bot", 30)], tagged: [(.service, ["t"]), (.key("k1"), ["t"])])]
        }
        #expect(try #require(history.first).points.map(\.total) == [100, 100])
    }

    @Test func aTargetWithoutACostInAMonthIsLeftOutAndFlagged() throws {
        let history = TagHistory.compute(months: [september, october]) { month in
            [service("A", present: [state(.key("k1"), "Bot", 30), state(.key("k2"), "Cron", month == october ? nil : 12)],
                     tagged: [(.key("k1"), ["t"]), (.key("k2"), ["t"])])]
        }
        let points = try #require(history.first).points
        #expect(points.map(\.total) == [42, 30])
        #expect(points.map(\.hasUnavailableTargets) == [false, true])
    }

    // MARK: Shares per service, estimates

    @Test func theTotalIsSplitPerTrackedServiceAndDifferentServicesAreAdded() throws {
        let history = TagHistory.compute(months: [november]) { _ in
            [service("Vercel", present: [state(project("web"), "web", 25)], tagged: [(project("web"), ["t"])]),
             service("Neon", present: [state(.usageProject(organization: "Org", name: "api"), "api", 4, estimate: true)],
                     tagged: [(.usageProject(organization: "Org", name: "api"), ["t"])])]
        }
        let point = try #require(history.first?.points.first)
        #expect(point.total == 29)
        #expect(point.services == [.init(serviceName: "Neon", amount: 4, isEstimate: true),
                                   .init(serviceName: "Vercel", amount: 25, isEstimate: false)])
        #expect(point.isApproximate)
    }

    @Test func twoServicesWithTheSameNameStayApart() throws {
        let first = TagServiceInput(serviceID: UUID(), serviceName: "Neon", spend: 5, present: [],
                                    assignments: [TagAssignment(target: .service, displayName: "Neon", tags: ["t"])])
        let second = TagServiceInput(serviceID: UUID(), serviceName: "Neon", spend: 7, present: [],
                                     assignments: [TagAssignment(target: .service, displayName: "Neon", tags: ["t"])])
        let point = try #require(TagHistory.compute(months: [november]) { _ in [first, second] }.first?.points.first)
        #expect(point.total == 12)
        #expect(point.services.map(\.amount).sorted() == [5, 7])
    }

    // MARK: Several tags, ordering, summary

    @Test func tagsKeepTheNewestSpellingAndAreOrderedByTheNewestMonthsTotal() throws {
        let history = TagHistory.compute(months: [october, november]) { month in
            [service("A", spend: month == october ? 90 : 3, tagged: [(.service, [month == october ? "big" : "BIG"])]),
             service("B", spend: 20, tagged: [(.service, ["small"])])]
        }
        #expect(history.map(\.tag) == ["small", "BIG"]) // November decides the order; the spelling is November's
        #expect(history.first { $0.tag == "BIG" }?.points.map(\.total) == [90, 3])
    }

    @Test func theSummaryNamesTheLatestAndThePreviousMonthAndSumsOnlyKnownMonths() throws {
        let spend: [Month: Decimal?] = [september: nil, october: 7, november: 11]
        let tag = try #require(TagHistory.compute(months: [september, october, november]) { month in
            [service("A", spend: spend[month] ?? nil, tagged: [(.service, ["t"])])]
        }.first)
        #expect(tag.latest?.total == 11)
        #expect(tag.previous?.total == 7)
        #expect(tag.knownSum == 18)
        #expect(tag.monthsWithoutTotal == 1) // September has no data
    }

    @Test func noAssignmentsMeansNoHistory() {
        #expect(TagHistory.compute(months: [november]) { _ in [service("A", spend: 10, tagged: [])] }.isEmpty)
    }
}
