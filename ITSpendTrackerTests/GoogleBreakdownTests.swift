import Foundation
import Testing
@testable import ITSpendTracker

/// REQ-011: Google Cloud spend comes from the BigQuery billing export, net of credits and in USD, and is broken down by
/// Google service, project and billing account. Both properties are decided by the SQL text and its row mapping.
@Suite struct GoogleBreakdownTests {
    private let table = "`p.billing_export.gcp_billing_export_v1_0123AB_4567CD_89EF01`"
    private let from = Day(year: 2026, month: 8, day: 1)

    @Test func everyCostQueryNetsCreditsAndConvertsToUSD() {
        let queries = [GoogleCloudConnector.dailyCostSQL(table: table, from: from),
                       GoogleCloudConnector.monthlyBreakdownSQL(table: table, from: from),
                       GoogleCloudConnector.currentMonthServiceCostSQL(table: table, monthStart: from)]
        for sql in queries {
            #expect(sql.contains("cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)"), "credits are added (they are negative)")
            #expect(sql.contains("currency_conversion_rate"))
            #expect(sql.contains("IFNULL(NULLIF(currency_conversion_rate, 0), 1)"), "a missing or zero rate must not divide by zero")
            #expect(sql.contains("usage_start_time >= TIMESTAMP('2026-08-01')"))
            #expect(sql.contains(table))
        }
    }

    @Test func breakdownQueryGroupsByServiceProjectAndAccountPerMonth() {
        let sql = GoogleCloudConnector.monthlyBreakdownSQL(table: table, from: from)
        #expect(sql.contains("service.description AS service"))
        #expect(sql.contains("project.name AS project"))
        #expect(sql.contains("billing_account_id AS account"))
        #expect(sql.contains("GROUP BY month, service, project, account"))
        // Days are Pacific, the billing day of Google Cloud.
        #expect(sql.contains("'America/Los_Angeles'"))
    }

    @Test func severalExportTablesAreReadAsOne() {
        let tables = [GoogleCloudConnector.TableReference(project: "p", dataset: "a", table: "t1"),
                      GoogleCloudConnector.TableReference(project: "q", dataset: "b", table: "t2")]
        let source = GoogleCloudConnector.unionSource(tables)
        #expect(source.contains("UNION ALL"))
        for column in ["credits", "currency_conversion_rate", "service", "project", "billing_account_id"] {
            #expect(source.contains(column), "the union must keep \(column), the cost queries use it")
        }
        #expect(GoogleCloudConnector.unionSource([tables[0]]) == "`p.a.t1`")
    }

    @Test func fetchMapsRowsToServiceProjectAndAccountBreakdowns() async throws {
        let http = QueryRouter()
        http.stub.on("/token", #"{"access_token":"ya29.test","expires_in":3600}"#)
        http.stub.on("/bigquery/v2/projects/p/datasets/billing_export/tables", """
        {"tables":[{"tableReference":{"projectId":"p","datasetId":"billing_export","tableId":"gcp_billing_export_v1_0123AB_4567CD_89EF01"}}]}
        """)
        http.daily = [["2026-08-02", "4"], ["2026-09-02", "10"]]
        http.monthly = [["2026-09", "Compute Engine", "web-project", "0123AB-4567CD-89EF01", "6.5"],
                        ["2026-09", "Compute Engine", "web-project", "0123AB-4567CD-89EF01", "1.5"],   // same group: added up
                        ["2026-09", "Cloud Storage", "web-project", "0123AB-4567CD-89EF01", "2"],
                        ["2026-09", nil, nil, nil, "0.5"]]                                              // no service, project or account
        let json = String(data: try JSONSerialization.data(withJSONObject: [
            "client_email": "sa@p.iam.gserviceaccount.com", "private_key": try TestRSA.pkcs8PEM(), "project_id": "p",
        ]), encoding: .utf8)!
        let request = FetchRequest(credentials: ["serviceAccountJSON": json, "dataset": "billing_export"],
                                   from: Day(year: 2026, month: 8, day: 1), now: Date(timeIntervalSince1970: 1_790_726_400))
        let snapshot = try await GoogleCloudConnector(http: http).fetch(request)

        let september = Month(year: 2026, month: 9)
        let rows = try #require(snapshot.breakdown)
        func amount(_ dimension: BreakdownDimension, _ label: String) -> Decimal? {
            rows.first { $0.month == september && $0.dimension == dimension && $0.label == label }?.amount
        }
        #expect(amount(.lineItem, "Compute Engine") == 8)
        #expect(amount(.lineItem, "Cloud Storage") == 2)
        #expect(amount(.project, "web-project") == 10)
        #expect(amount(.account, "0123AB-4567CD-89EF01") == 10)
        #expect(amount(.lineItem, "Other") == Decimal(string: "0.5"))
        #expect(amount(.project, "No project") == Decimal(string: "0.5"))
        #expect(amount(.account, "Other") == Decimal(string: "0.5"))
        #expect(snapshot.breakdownFrom == Month(year: 2026, month: 8))
        #expect(snapshot.dailyCosts[Day(year: 2026, month: 9, day: 2)] == 10)
    }

    @Test func aFailingBreakdownQueryOnlyDropsTheBreakdown() async throws {
        let http = QueryRouter()
        http.stub.on("/token", #"{"access_token":"ya29.test","expires_in":3600}"#)
        http.stub.on("/bigquery/v2/projects/p/datasets/billing_export/tables", """
        {"tables":[{"tableReference":{"projectId":"p","datasetId":"billing_export","tableId":"gcp_billing_export_v1_0123AB_4567CD_89EF01"}}]}
        """)
        http.daily = [["2026-09-02", "10"]]
        http.monthlyFails = true
        let json = String(data: try JSONSerialization.data(withJSONObject: [
            "client_email": "sa@p.iam.gserviceaccount.com", "private_key": try TestRSA.pkcs8PEM(), "project_id": "p",
        ]), encoding: .utf8)!
        let request = FetchRequest(credentials: ["serviceAccountJSON": json, "dataset": "billing_export"],
                                   from: Day(year: 2026, month: 8, day: 1), now: Date(timeIntervalSince1970: 1_790_726_400))
        let snapshot = try await GoogleCloudConnector(http: http).fetch(request)
        #expect(snapshot.dailyCosts[Day(year: 2026, month: 9, day: 2)] == 10)   // spend is kept
        #expect(snapshot.breakdown == nil)                                       // unknown, not an empty breakdown
        #expect(snapshot.breakdownFrom == nil)
    }
}

/// Answers BigQuery `queries` POSTs by SQL text: daily cost, monthly breakdown or (empty) per-service cost.
private final class QueryRouter: HTTPClient, @unchecked Sendable {
    let stub = StubHTTP()
    var daily: [[String?]] = []
    var monthly: [[String?]] = []
    var monthlyFails = false

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.path().hasSuffix("/queries") == true else { return try await stub.send(request) }
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        func response(_ rows: [[String?]], status: Int = 200) throws -> (Data, HTTPURLResponse) {
            let cells = rows.map { row in ["f": row.map { ["v": $0 as Any? ?? NSNull()] }] }
            let json = try JSONSerialization.data(withJSONObject: ["jobComplete": true, "rows": cells,
                                                                   "jobReference": ["jobId": "j", "location": "US"]])
            return (json, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        if body.contains("project.name AS project") {
            if monthlyFails { return (Data(#"{"error":{"message":"boom"}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!) }
            return try response(monthly)
        }
        if body.contains("service.id AS service") { return try response([]) }
        return try response(daily)
    }
}
