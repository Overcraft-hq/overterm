import XCTest

@testable import Overterm
@testable import OvertermCore

/// A GraphQL schema read from introspection, and what a query completes to
/// at each place — read from the text alone.
final class GraphQLSchemaTests: XCTestCase {
    private func schema() throws -> GraphQLSchema { try GraphQLSchema.parse(Data(E2EEchoServer.graphQLSchema.utf8)) }

    func testIntrospectionIsRead() throws {
        let schema = try schema()
        XCTAssertEqual(schema.queryType, "Query")
        XCTAssertEqual(schema.mutationType, "Mutation")
        XCTAssertEqual(schema.browsable.prefix(2).map(\.name), ["Query", "Mutation"], "the roots first")
        XCTAssertFalse(schema.browsable.contains { $0.name.hasPrefix("__") }, "the schema's own types aren't browsed")
        let posts = try XCTUnwrap(schema.types["User"]?.fields.first { $0.name == "posts" })
        XCTAssertEqual(posts.type.display, "[Post!]!")
        XCTAssertEqual(posts.type.named, "Post")
        XCTAssertEqual(schema.types["Query"]?.fields.first?.arguments.first?.type.display, "ID!")
        XCTAssertEqual(schema.types["Role"]?.enumValues, ["ADMIN", "MEMBER"])
    }

    func testAServersRefusalIsSaid() {
        XCTAssertThrowsError(try GraphQLSchema.parse(Data(#"{"errors":[{"message":"introspection is disabled"}]}"#.utf8))) {
            XCTAssertEqual($0.localizedDescription, "introspection is disabled")
        }
        XCTAssertThrowsError(try GraphQLSchema.parse(Data("<html>".utf8)))
    }

    func testThePlaceOfTheCaret() throws {
        let schema = try schema()
        XCTAssertEqual(schema.place(before: ""), .document)
        XCTAssertEqual(schema.place(before: "{ "), .field("Query"), "a shorthand query")
        XCTAssertEqual(schema.place(before: "query Q { user(id: 1) { "), .field("User"))
        XCTAssertEqual(schema.place(before: "query { user(id: 1) { posts { "), .field("Post"))
        XCTAssertEqual(schema.place(before: "query { user(id: 1) { posts { title } "), .field("User"), "back out of posts")
        XCTAssertEqual(schema.place(before: "mutation { "), .field("Mutation"))
        XCTAssertEqual(schema.place(before: "{ user("), .argument(type: "Query", field: "user"))
        XCTAssertEqual(schema.place(before: "{ me: user(id: 2) { "), .field("User"), "an alias")
        XCTAssertEqual(schema.place(before: "query Q($id: "), .type)
        XCTAssertEqual(schema.place(before: "{ user { ... on "), .type)
        XCTAssertEqual(schema.place(before: "{ user(id: \"a { b\") { "), .field("User"), "a brace in a string isn't one")
        XCTAssertEqual(schema.place(before: "# { \n{ "), .field("Query"), "nor in a comment")
    }

    func testCompletion() throws {
        let schema = try schema()
        XCTAssertEqual(schema.complete(before: "{ user(id: 1) { na").candidates.map(\.label), ["name"])
        XCTAssertEqual(schema.complete(before: "{ user(id: 1) { na").typed, "na")
        XCTAssertEqual(schema.complete(before: "{ us").candidates.map(\.label), ["user", "users"])
        XCTAssertEqual(schema.complete(before: "{ us").candidates.first?.detail, "User")
        XCTAssertEqual(schema.complete(before: "mutation { rename(").candidates.map(\.label), ["id", "name"])
        XCTAssertEqual(schema.complete(before: "que").candidates.map(\.label), ["query"])
        XCTAssertTrue(schema.complete(before: "query Q($id: ").candidates.map(\.label).contains("ID"))
    }

    func testANewGraphQLRequestIsBrunos() {
        let file = BruFile.newGraphQLRequest(name: "Users", url: "{{baseUrl}}/graphql", seq: 2)
        XCTAssertEqual(file.requestType, "graphql")
        XCTAssertEqual(file.method, "POST")
        XCTAssertEqual(file.bodyMode, .graphql)
        XCTAssertTrue(file.text.contains("body:graphql {\n  query {\n"), file.text)
        XCTAssertEqual(BruFile(parsing: file.text).text, file.text, "it reads back the same")
    }
}
