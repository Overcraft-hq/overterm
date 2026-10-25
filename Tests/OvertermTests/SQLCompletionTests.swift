import XCTest

@testable import Overterm

/// Completion in a console, from a catalog.
final class SQLCompletionTests: XCTestCase {
    private let catalog = SQLCompletion.Catalog(
        schemas: ["public", "billing"], defaultSchema: "public",
        tables: [
            "public": [CatalogTable(schema: "public", name: "orders"), CatalogTable(schema: "public", name: "order_items", isView: true)],
            "billing": [CatalogTable(schema: "billing", name: "invoices")],
        ],
        columns: [
            "public": [
                CatalogColumn(table: "orders", name: "id", type: "int4"), CatalogColumn(table: "orders", name: "total", type: "numeric"),
                CatalogColumn(table: "order_items", name: "order_id", type: "int4"),
            ],
            "billing": [CatalogColumn(table: "invoices", name: "amount", type: "numeric")],
        ])

    private func labels(_ before: String, statement: String? = nil) -> [String] {
        SQLCompletion.candidates(SQLText.completionContext(before: before), statement: statement ?? before, catalog: catalog).map(\.label)
    }

    func testTablesAfterFromAndJoin() {
        XCTAssertEqual(labels("select * from ord"), ["orders", "order_items"])
        XCTAssertEqual(labels("select * from billing.in"), ["invoices"])
        XCTAssertTrue(labels("select * from ").contains("billing"), "schemas too")
    }

    func testColumnsAfterAnAliasATableOrASchema() {
        let statement = "select o.  from orders o join billing.invoices i on true"
        XCTAssertEqual(labels("select o.", statement: statement), ["id", "total"])
        XCTAssertEqual(labels("select i.am", statement: statement), ["amount"])
        XCTAssertEqual(labels("select orders.to"), ["total"])
        XCTAssertEqual(labels("select * from x where billing."), ["invoices"])
    }

    func testAnywhereTheStatementsColumnsThenKeywordsInTheCaseTyped() {
        let found = labels("select to", statement: "select to from orders")
        XCTAssertEqual(found.first, "total", "the statement's own columns first")
        XCTAssertTrue(labels("select * from orders wh", statement: "select * from orders wh").contains("where"))
        XCTAssertTrue(labels("SELECT * FROM orders WH", statement: "SELECT * FROM orders WH").contains("WHERE"))
        XCTAssertEqual(labels("select "), [], "nothing typed, nothing offered")
    }

    func testWhatMustBeReadFirst() {
        var empty = catalog
        empty.columns = [:]
        let context = SQLText.completionContext(before: "select o.")
        XCTAssertEqual(SQLCompletion.missing(context, statement: "select o. from billing.invoices o", catalog: empty), ["billing", "public"])
    }
}
