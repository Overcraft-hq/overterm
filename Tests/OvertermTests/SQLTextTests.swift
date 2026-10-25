import XCTest

@testable import Overterm

/// SQL as text: its statements, what they do, what the caret is writing.
final class SQLTextTests: XCTestCase {
    private func split(_ text: String) -> [String] {
        SQLText.statements(in: text).map { (text as NSString).substring(with: $0) }
    }

    func testStatementsSplitOnSemicolonsOutsideStringsAndComments() {
        XCTAssertEqual(split("select 1;  select 2 ;\n\nselect 3"), ["select 1", "select 2", "select 3"])
        XCTAssertEqual(split("select ';' as a; select \"x;y\" from t"), ["select ';' as a", "select \"x;y\" from t"])
        XCTAssertEqual(split("select 1 -- no; split\n; select 2"), ["select 1 -- no; split", "select 2"])
        XCTAssertEqual(split("/* a; b */ select 1; # mysql; comment\nselect 2"), ["/* a; b */ select 1", "# mysql; comment\nselect 2"])
        XCTAssertEqual(
            split("create function f() returns int as $$ select 1; $$ language sql; select 2"),
            ["create function f() returns int as $$ select 1; $$ language sql", "select 2"])
        XCTAssertEqual(split("select 'it''s; fine'; select 'a\\'b;c'"), ["select 'it''s; fine'", "select 'a\\'b;c'"])
        XCTAssertEqual(split(" ;; \n "), [])
    }

    func testTheStatementAtTheCaret() {
        let text = "select 1;\nselect 2;\n\nselect 3"
        func at(_ caret: Int) -> String? { SQLText.statement(at: caret, in: text).map { (text as NSString).substring(with: $0) } }
        XCTAssertEqual(at(3), "select 1")
        XCTAssertEqual(at(15), "select 2")
        XCTAssertEqual(at(20), "select 2", "between two: the one just left")
        XCTAssertEqual(at((text as NSString).length), "select 3")
    }

    func testWhatAStatementDoes() {
        XCTAssertEqual(SQLText.verb(of: "  -- note\n/* x */ select 1"), "SELECT")
        XCTAssertTrue(SQLText.onlyReads("WITH x AS (select 1) select * from x"))
        XCTAssertFalse(SQLText.onlyReads("insert into t values (1)"))
        XCTAssertNotNil(SQLText.danger(of: "DELETE FROM orders"))
        XCTAssertNil(SQLText.danger(of: "delete from orders where id = 1"))
        XCTAssertNotNil(SQLText.danger(of: "update users set name = 'where'"), "a WHERE in a string isn't one")
        XCTAssertNotNil(SQLText.danger(of: "drop table users"))
        XCTAssertNotNil(SQLText.danger(of: "truncate t"))
        XCTAssertNil(SQLText.danger(of: "select * from t"))
    }

    func testTheCompletionContext() {
        XCTAssertEqual(SQLText.completionContext(before: "select * from ord"), .table(schema: nil, prefix: "ord"))
        XCTAssertEqual(SQLText.completionContext(before: "select * from public.us"), .table(schema: "public", prefix: "us"))
        XCTAssertEqual(SQLText.completionContext(before: "select * from orders o join "), .table(schema: nil, prefix: ""))
        XCTAssertEqual(SQLText.completionContext(before: "select o.to"), .qualifiedColumn(table: "o", prefix: "to"))
        XCTAssertEqual(SQLText.completionContext(before: "select \"Users\"."), .qualifiedColumn(table: "Users", prefix: ""))
        XCTAssertEqual(SQLText.completionContext(before: "select * from orders where sta"), .any(prefix: "sta"))
        XCTAssertEqual(SQLText.completionContext(before: "sel"), .any(prefix: "sel"))
    }

    func testTheTablesAStatementNames() {
        let tables = SQLText.tables(in: "select * from orders o join public.users as u on u.id = o.user_id left join items where x")
        XCTAssertEqual(tables.map(\.name), ["orders", "users", "items"])
        XCTAssertEqual(tables.map(\.alias), ["o", "u", nil])
        XCTAssertEqual(tables.map(\.schema), [nil, "public", nil])
        XCTAssertEqual(SQLText.tables(in: "update `shop`.`orders` set x = 1").first?.schema, "shop")
    }
}
