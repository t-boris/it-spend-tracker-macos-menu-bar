import Foundation
import Testing
@testable import ITSpendTracker

/// REQ-023, REQ-024: the history the pages read from the model follows the data, and the speed-ups change no figure.
@Suite @MainActor struct TagHistoryModelTests {
    private func manualService(_ model: AppModel, name: String, amount: Decimal) throws -> TrackedService {
        let service = try model.store.addManualService(name: name)
        let start = model.today.calendarMonth.adding(months: -3).firstDay
        try model.store.addSubscription(service, name: name, period: .monthly, start: start, end: nil, amount: amount)
        return service
    }

    @Test func theHistoryCoversTwelveMonthsEndingWithTheCurrentOne() throws {
        let model = AppModel()
        let service = try manualService(model, name: "Notes", amount: 10)
        try model.store.setTags(["web"], for: .service, displayName: "Notes", of: service)
        let points = try #require(model.tagHistory.first).points
        #expect(points.count == 12)
        #expect(points.last?.month == model.today.calendarMonth)
        #expect(points.last?.state == .amount && points.last?.total == 10)
        // A manual service has no usage, so before its subscription started its spend is a real zero (as on the
        // History tab); "no data" is only for a connected service before its coverage begins (see TagHistoryTests).
        #expect(points.first?.state == .amount && points.first?.total == 0)
    }

    @Test func theCachedHistoryFollowsEveryTagEdit() throws {
        let model = AppModel()
        let service = try manualService(model, name: "Notes", amount: 10)
        #expect(model.tagHistory.isEmpty)
        try model.store.setTags(["web"], for: .service, displayName: "Notes", of: service)
        #expect(model.tagHistory.map(\.tag) == ["web"])
        #expect(model.tagHistory.map(\.tag) == ["web"]) // served from the cache, same answer
        try model.store.setTags(["web", "ops"], for: .service, displayName: "Notes", of: service)
        #expect(Set(model.tagHistory.map(\.tag)) == ["web", "ops"])
        try model.store.setTags([], for: .service, displayName: "Notes", of: service)
        #expect(model.tagHistory.isEmpty)
        #expect(model.tagTotals.isEmpty)
    }

    @Test func theCachedTotalsFollowTheDataToo() throws {
        let model = AppModel()
        let service = try manualService(model, name: "Notes", amount: 10)
        try model.store.setTags(["web"], for: .service, displayName: "Notes", of: service)
        #expect(model.tagTotals.first?.total == 10)
        try model.store.addSubscription(service, name: "Extra", period: .monthly,
                                        start: model.today.calendarMonth.adding(months: -3).firstDay, end: nil, amount: 5)
        #expect(model.tagTotals.first?.total == 15)
        #expect(model.tagHistory.first?.latest?.total == 15)
    }

    @Test func openingATaggedItemGoesToItsPageOrToTheSectionOfItsService() throws {
        let model = AppModel()
        let id = UUID()
        let web = TagTarget.breakdownItem(dimension: .project, label: "web")
        let input = TagServiceInput(serviceID: id, serviceName: "A", spend: 5,
                                    present: [TagTargetState(target: .key("k1"), name: "Bot", cost: 1, costIsEstimate: false),
                                              TagTargetState(target: web, name: "web", cost: 2, costIsEstimate: false)],
                                    assignments: [TagTarget.service, .key("k1"), web].map {
                                        TagAssignment(target: $0, displayName: "stored", tags: ["t"])
                                    })
        let members = try #require(TagTotal.compute([input]).first).members
        func route(_ target: TagTarget) throws -> Route? { model.route(opening: try #require(members.first { $0.target == target })) }
        #expect(try route(.service) == .service(id))
        #expect(try route(.key("k1")) == .key(service: id, key: "k1"))
        model.pendingServiceSection = nil
        #expect(try route(web) == .service(id))
        #expect(model.pendingServiceSection == .breakdown) // the service page scrolls to the breakdown
    }

    @Test func buildingTheLedgerOnceGivesTheSameInputAsBuildingItEveryTime() throws {
        let model = AppModel()
        let service = try manualService(model, name: "Notes", amount: 10)
        try model.store.setTags(["web"], for: .service, displayName: "Notes", of: service)
        let ledger = service.ledger
        for month in TagHistory.months(endingAt: model.today.calendarMonth) {
            let each = TagTotal.compute([service.tagInput(in: month)])
            let once = TagTotal.compute([service.tagInput(in: month, ledger: ledger)])
            #expect(each == once)
        }
    }
}
