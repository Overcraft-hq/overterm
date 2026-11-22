import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI

/// MongoDB's pure parts: BSON both ways, the shell's values and statements,
/// what reads and what destroys, answers as rows, connection strings, SCRAM
/// against the RFCs' own examples, SRV records.
final class MongoTests: XCTestCase {
    // MARK: BSON

    func testBSONIsTheSpecsBytes() throws {
        // bsonspec.org's own example.
        let hello: BSONDocument = ["hello": .string("world")]
        XCTAssertEqual(
            [UInt8](hello.encoded()),
            [0x16, 0, 0, 0, 0x02, 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0, 0x06, 0, 0, 0, 0x77, 0x6F, 0x72, 0x6C, 0x64, 0, 0])
        XCTAssertEqual(try BSONDocument.decode(hello.encoded()), hello)
    }

    func testEveryTypeRoundTrips() throws {
        let id = try XCTUnwrap(ObjectID(hex: "507f1f77bcf86cd799439011"))
        let document: BSONDocument = [
            "d": .double(2.5), "s": .string("çağ 🍃"), "o": .document(["x": .int32(1)]), "a": .array([.int32(1), .string("two")]),
            "b": .binary(subtype: 4, Data(repeating: 7, count: 16)), "u": .undefined, "id": .objectId(id), "t": .bool(true),
            "at": .date(1_772_900_000_000), "n": .null, "re": .regex(pattern: "^a", options: "mi"), "js": .javascript("1"),
            "i": .int32(-5), "ts": .timestamp(1 << 32 | 7), "l": .int64(1 << 40), "dec": .decimal128(Decimal128("1.50")!), "min": .minKey,
            "max": .maxKey,
        ]
        let back = try BSONDocument.decode(document.encoded())
        XCTAssertEqual(back.keys, document.keys, "the order kept")
        XCTAssertEqual(back["re"], .regex(pattern: "^a", options: "im"), "a regex's flags sorted, as the spec asks")
        var expected = document
        expected["re"] = .regex(pattern: "^a", options: "im")
        XCTAssertEqual(back, expected)
        XCTAssertThrowsError(try BSONDocument.decode(Data([5, 0, 0, 0])), "cut short")
    }

    func testDecimal128() throws {
        XCTAssertEqual(Decimal128("1")?.high, 0x3040_0000_0000_0000)
        XCTAssertEqual(Decimal128("1")?.low, 1)
        XCTAssertEqual(Decimal128("0.1")?.high, 0x303E_0000_0000_0000)
        for text in ["1.50", "-0.001", "0", "123456789012345678901234567890.1234", "1E+3", "NaN", "Infinity", "-Infinity"] {
            XCTAssertEqual(Decimal128(text)?.text, text, text)
        }
        XCTAssertEqual(Decimal128("1e-10")?.text, "1E-10")
        XCTAssertNil(Decimal128("12345678901234567890123456789012345"), "35 digits don't fit")
        XCTAssertNil(Decimal128("1.2.3"))
    }

    func testObjectIDsAreMadeAsDriversMakeThem() throws {
        let now = Date(timeIntervalSince1970: 1_772_900_000)
        let a = ObjectID.generate(now: now)
        let b = ObjectID.generate(now: now)
        XCTAssertEqual(a.hex.count, 24)
        XCTAssertEqual(String(a.hex.prefix(8)), String(format: "%08x", 1_772_900_000), "the time first")
        XCTAssertNotEqual(a, b, "the counter moves")
        XCTAssertEqual(ObjectID(hex: a.hex), a)
        XCTAssertNil(ObjectID(hex: "xyz"))
    }

    func testValuesAsTheShellWritesThem() {
        let id = ObjectID(hex: "507f1f77bcf86cd799439011")!
        let value: BSONValue = .document([
            "_id": .objectId(id), "at": .date(0), "n": .int64(5), "tags": .array([.string("a"), .null]), "price": .decimal128(Decimal128("9.99")!),
        ])
        XCTAssertEqual(
            value.shell,
            #"{ "_id": ObjectId("507f1f77bcf86cd799439011"), "at": ISODate("1970-01-01T00:00:00.000Z"), "n": NumberLong("5"), "tags": ["a", null], "price": NumberDecimal("9.99") }"#
        )
        XCTAssertEqual(BSONValue.string("plain").cell, "plain", "a string's cell is itself")
        XCTAssertEqual(BSONValue.date(0).cell, "1970-01-01T00:00:00.000Z")
        XCTAssertNil(BSONValue.null.cell)
        XCTAssertEqual(
            BSONValue.binary(subtype: 4, MongoShellParser.uuidBytes(UUID(uuidString: "6A2F41A3-C54C-4BB6-8E2E-2B9A4B2C1D3E")!)).shell,
            #"UUID("6a2f41a3-c54c-4bb6-8e2e-2b9a4b2c1d3e")"#)
    }

    // MARK: The shell's values

    private func parse(_ text: String) throws -> BSONValue {
        var parser = MongoShellParser(text)
        let value = try parser.value()
        XCTAssertTrue(parser.atEnd, text)
        return value
    }

    func testTheShellsNotationReads() throws {
        let value = try parse(
            #"""
            {
              _id: ObjectId("507f1f77bcf86cd799439011"),  // a comment
              at: ISODate("2026-03-07T16:13:20Z"), day: new Date('2026-03-07'),
              n: NumberLong(5), i: NumberInt("7"), d: NumberDecimal("1.50"),
              'quoted key': "it's \"x\"\n", list: [1, 2.5, -3, 3000000000, 0x10], re: /a\/b[/]c/i,
              nested: { a: null, b: true, c: undefined }, /* block */ $set: 1, "a.b": MinKey,
              ext: { "$oid": "507f1f77bcf86cd799439011" }, ejsonDate: { "$date": { "$numberLong": "1000" } },
              long: { "$numberLong": "9007199254740993" }, op: { $regex: "^a", $options: "i" },
            }
            """#)
        let d = try XCTUnwrap(value.document)
        let id = ObjectID(hex: "507f1f77bcf86cd799439011")!
        XCTAssertEqual(d["_id"], .objectId(id))
        XCTAssertEqual(d["at"], .date(1_772_900_000_000))
        XCTAssertEqual(d["day"], .date(1_772_841_600_000), "a date alone is midnight UTC")
        XCTAssertEqual(d["n"], .int64(5))
        XCTAssertEqual(d["i"], .int32(7))
        XCTAssertEqual(d["d"], .decimal128(Decimal128("1.50")!))
        XCTAssertEqual(d["quoted key"], .string("it's \"x\"\n"))
        XCTAssertEqual(d["list"], .array([.int32(1), .double(2.5), .int32(-3), .int64(3_000_000_000), .int32(16)]))
        XCTAssertEqual(d["re"], .regex(pattern: "a/b[/]c", options: "i"))
        XCTAssertEqual(d["nested"], .document(["a": .null, "b": .bool(true), "c": .undefined]))
        XCTAssertEqual(d["$set"], .int32(1))
        XCTAssertEqual(d["a.b"], .minKey)
        XCTAssertEqual(d["ext"], .objectId(id), "Extended JSON's $oid")
        XCTAssertEqual(d["ejsonDate"], .date(1000), "canonical $date")
        XCTAssertEqual(d["long"], .int64(9_007_199_254_740_993))
        XCTAssertEqual(d["op"], .document(["$regex": .string("^a"), "$options": .string("i")]), "a query operator is left as it is")
    }

    func testWhatIsntAValueIsSaid() {
        XCTAssertThrowsError(try parse("{ a: x }")) { XCTAssertTrue("\($0.localizedDescription)".contains("variables"), $0.localizedDescription) }
        XCTAssertThrowsError(try parse("{ a: Math.random() }"))
        XCTAssertThrowsError(try parse(#"{ a: ObjectId("nope") }"#))
        XCTAssertThrowsError(try parse("{ a: `x${y}` }"))
        XCTAssertThrowsError(try parse(#"{ a: "unended }"#))
    }

    // MARK: Statements

    private func statements(_ text: String) -> [String] {
        MongoText.statements(in: text).map { (text as NSString).substring(with: $0) }
    }

    func testAConsoleIsALineOrABlock() {
        let text = """
            // the open ones
            db.orders.find({
              status: "open; or {not}",
              note: /"/
            })
              .sort({ at: -1 })
            show dbs; use shop

            /* nothing here */
            db.orders.countDocuments({})
            """
        XCTAssertEqual(
            statements(text),
            [
                "db.orders.find({\n  status: \"open; or {not}\",\n  note: /\"/\n})\n  .sort({ at: -1 })", "show dbs", "use shop",
                "db.orders.countDocuments({})",
            ])
        let caret = (text as NSString).range(of: "status").location
        XCTAssertEqual(MongoText.statement(at: caret, in: text).map { (text as NSString).substring(with: $0) }?.hasPrefix("db.orders.find"), true)
        XCTAssertNil(MongoText.statement(at: 0, in: text), "a comment is no statement")
        XCTAssertEqual(DatabaseKind.mongodb.statements(in: text).count, 4)
        XCTAssertEqual(DatabaseKind.documentdb.statements(in: text).count, 4, "DocumentDB's console is the same")
    }

    func testFindAndItsChain() throws {
        let find = try MongoText.command(#"db.orders.find({ status: "open" }, { total: 1 }).sort({ at: -1 }).skip(5).limit(10)"#)
        XCTAssertEqual(find.collection, "orders")
        XCTAssertEqual(find.method, "find")
        XCTAssertEqual(find.action, .cursor)
        XCTAssertEqual(find.limit, 10)
        XCTAssertEqual(
            find.body,
            [
                "find": .string("orders"), "filter": .document(["status": .string("open")]), "projection": .document(["total": .int32(1)]),
                "sort": .document(["at": .int32(-1)]), "skip": .int64(5),
            ])
        let one = try MongoText.command("db.getCollection('order items').findOne({})")
        XCTAssertEqual(one.collection, "order items")
        XCTAssertEqual(one.action, .findOne)
        let dotted = try MongoText.command("db.system.profile.find()")
        XCTAssertEqual(dotted.collection, "system.profile", "a name with dots")
        let sibling = try MongoText.command(#"db.getSiblingDB("other")["c-1"].find({}).count()"#)
        XCTAssertEqual(sibling.database, "other")
        XCTAssertEqual(sibling.collection, "c-1")
        XCTAssertEqual(sibling.body, ["count": .string("c-1"), "query": .document([:])])
        XCTAssertThrowsError(try MongoText.command("db.orders.find().forEach(printjson)"))
        XCTAssertThrowsError(try MongoText.command("var x = db.orders.find()"))
        XCTAssertThrowsError(try MongoText.command("db.orders"), "nothing called")
        XCTAssertThrowsError(try MongoText.command("db.orders.find() db.x.find()"), "two at once")
    }

    func testTheOtherMethods() throws {
        let aggregate = try MongoText.command(#"db.orders.aggregate([{ $match: { a: 1 } }, { $group: { _id: "$s", n: { $sum: 1 } } }], { allowDiskUse: true })"#)
        XCTAssertEqual(aggregate.body["allowDiskUse"], .bool(true))
        XCTAssertEqual(aggregate.body["pipeline"]?.array?.count, 2)
        XCTAssertThrowsError(try MongoText.command("db.orders.aggregate([{ match: 1 }])"), "a stage starts with $")
        let count = try MongoText.command("db.orders.countDocuments({ a: 1 }, { limit: 5 })")
        XCTAssertEqual(count.action, .count)
        XCTAssertEqual(count.body["pipeline"]?.array?.count, 3)
        let insert = try MongoText.command(#"db.orders.insertMany([{ a: 1 }, { _id: 7, a: 2 }])"#)
        let documents = try XCTUnwrap(insert.body["documents"]?.array?.compactMap(\.document))
        XCTAssertEqual(documents[0].keys, ["_id", "a"], "an id made, first")
        if case .objectId = documents[0]["_id"] {} else { XCTFail("an ObjectId") }
        XCTAssertEqual(documents[1]["_id"], .int32(7), "its own kept")
        let update = try MongoText.command("db.orders.updateMany({}, { $set: { seen: true } }, { upsert: true })")
        XCTAssertEqual(
            update.body["updates"],
            .array([.document(["q": .document([:]), "u": .document(["$set": .document(["seen": .bool(true)])]), "multi": .bool(true), "upsert": .bool(true)])]))
        XCTAssertThrowsError(try MongoText.command("db.orders.updateOne({}, { seen: true })"), "an update needs operators")
        XCTAssertThrowsError(try MongoText.command("db.orders.replaceOne({}, { $set: { a: 1 } })"), "a replacement has none")
        XCTAssertNoThrow(try MongoText.command(#"db.orders.updateOne({}, [{ $set: { a: "$b" } }])"#), "a pipeline update")
        XCTAssertThrowsError(try MongoText.command("db.orders.deleteMany()"), "a delete takes a filter — {} for all")
        XCTAssertEqual(try MongoText.command("db.orders.deleteOne({ a: 1 })").body["deletes"]?.array?.first?.document?["limit"], .int32(1))
        XCTAssertEqual(try MongoText.command("db.orders.createIndex({ email: 1, at: -1 })").body["indexes"]?.array?.first?.document?["name"], .string("email_1_at_-1"))
        XCTAssertEqual(try MongoText.command("db.runCommand('ping')").body, ["ping": .int32(1)])
        XCTAssertEqual(try MongoText.command("db.adminCommand({ listDatabases: 1 })").database, "admin")
        XCTAssertEqual(try MongoText.command("show collections").action, .showCollections)
        XCTAssertEqual(try MongoText.command("show dbs").action, .showDatabases)
        XCTAssertEqual(try MongoText.command("use shop;").action, .use("shop"))
        let modify = try MongoText.command(#"db.orders.findOneAndUpdate({ a: 1 }, { $inc: { n: 1 } }, { returnDocument: "after" })"#)
        XCTAssertEqual(modify.body["new"], .bool(true))
    }

    @MainActor func testWhatReadsAndWhatDestroys() {
        let kind = DatabaseKind.mongodb
        for read in [
            "db.orders.find({})", "db.orders.aggregate([{ $match: {} }])", "db.orders.countDocuments({})", "show dbs", "use x",
            "db.runCommand({ ping: 1 })", "db.orders.getIndexes()", "db.orders.distinct('a')", "db.getCollectionNames()",
            "db.runCommand({ explain: { delete: 'orders', deletes: [] } })",
        ] {
            XCTAssertTrue(kind.onlyReads(read), read)
            XCTAssertTrue(kind.agentReads(read), read)
        }
        for write in [
            "db.orders.insertOne({ a: 1 })", "db.orders.aggregate([{ $out: 'copy' }])", "db.orders.aggregate([{ $merge: { into: 'x' } }])",
            "db.runCommand({ drop: 'orders' })", "db.orders.drop()", "db.dropDatabase()", "db.orders.find(", "nonsense",
            "db.runCommand({ eval: 'x' })", "db.orders.createIndex({ a: 1 })",
        ] {
            XCTAssertFalse(kind.onlyReads(write), write)
            XCTAssertFalse(kind.agentReads(write), write)
        }
        XCTAssertEqual(kind.danger(of: "db.orders.deleteMany({})"), "deleteMany({}) deletes every document in orders.")
        XCTAssertNotNil(kind.danger(of: "db.orders.deleteMany({ a: 1 })"))
        XCTAssertNil(kind.danger(of: "db.orders.deleteOne({ a: 1 })"))
        XCTAssertNotNil(kind.danger(of: "db.orders.updateMany({}, { $set: { a: 1 } })"))
        XCTAssertNil(kind.danger(of: "db.orders.updateMany({ a: 2 }, { $set: { a: 1 } })"))
        XCTAssertNotNil(kind.danger(of: "db.orders.drop()"))
        XCTAssertNotNil(kind.danger(of: "db.dropDatabase()"))
        XCTAssertNotNil(kind.danger(of: "db.orders.aggregate([{ $out: 'copy' }])"))
        XCTAssertNotNil(kind.danger(of: "db.runCommand({ drop: 'orders' })"))
        XCTAssertEqual(kind.verb(of: "db.orders.insertOne({ a: 1 })"), "insertOne")
        XCTAssertEqual(kind.verb(of: "db.orders.insertOne({ a: "), "insertOne", "named even unread")
        XCTAssertEqual(kind.subject(of: "db.orders.find({})"), "orders")
        XCTAssertEqual(kind.subject(of: "db.runCommand({ find: 'items' })"), "items")
        XCTAssertEqual(SQLConsoleView.title(SQLConsole.Run(sql: "db.orders.insertOne({})"), index: 0, kind: .mongodb), "insertOne orders")
    }

    // MARK: Answers

    func testDocumentsAsRows() {
        let id = ObjectID(hex: "507f1f77bcf86cd799439011")!
        let result = MongoResult.rows(
            [
                ["name": .string("Ada"), "_id": .objectId(id), "tags": .array([.string("a")])],
                ["_id": .int32(2), "name": .null, "address": .document(["city": .string("İzmir")])],
                ["_id": .int32(3)],
            ], limit: 2)
        XCTAssertEqual(result.columns, ["_id", "name", "tags", "address"], "_id first, then as met")
        XCTAssertEqual(result.types, ["mixed", "string", "array", "object"], "an ObjectId and an int: several types, said")
        XCTAssertEqual(
            result.rows,
            [
                [#"ObjectId("507f1f77bcf86cd799439011")"#, "Ada", #"["a"]"#, nil],
                ["2", nil, nil, #"{ "city": "İzmir" }"#],
            ])
        XCTAssertTrue(result.truncated)
        let fields = MongoResult.fields(["ok": .double(1), "version": .string("7.0.1")])
        XCTAssertEqual(fields.rows, [["ok", "1.0"], ["version", "7.0.1"]])
        let insert = try! MongoText.command("db.c.insertMany([{ _id: 1 }, { _id: 2 }])")
        let said = MongoResult.write(["n": .int32(2), "ok": .double(1)], command: insert)
        XCTAssertEqual(said.message, "2 inserted")
        XCTAssertEqual(said.affected, 2)
        XCTAssertEqual(said.rows, [["1"], ["2"]], "the ids made")
        let update = try! MongoText.command("db.c.updateMany({}, { $set: { a: 1 } })")
        XCTAssertEqual(MongoResult.write(["n": .int32(3), "nModified": .int32(2), "ok": .double(1)], command: update).message, "3 matched, 2 modified")
        XCTAssertEqual(
            MongoDriver.fields(of: [["a": .null, "_id": .int32(1)], ["a": .string("x"), "b": .bool(true)]]).map { "\($0.name) \($0.type)" },
            ["_id int", "a string", "b bool"])
    }

    func testTheWireMessage() throws {
        let bytes = MongoWire.message(["ping": .int32(1), "$db": .string("admin")], requestID: 9)
        XCTAssertEqual(Int(bytes[0]) | Int(bytes[1]) << 8, bytes.count, "its length first")
        XCTAssertEqual(Array(bytes[12..<16]), [0xDD, 0x07, 0, 0], "OP_MSG")
        // An answer to it, as a server writes one: header, flags, a body.
        let ok: BSONDocument = ["ok": .double(1)]
        let body = ok.encoded()
        var reply: [UInt8] = []
        func append(_ n: Int32) { withUnsafeBytes(of: n.littleEndian) { reply += $0 } }
        append(Int32(16 + 4 + 1 + body.count))
        append(100)
        append(9)
        append(2013)
        append(0)
        reply.append(0)
        reply += body
        let read = try XCTUnwrap(try MongoWire.reply(reply + [1, 2]))
        XCTAssertEqual(read.responseTo, 9)
        XCTAssertEqual(read.body, ["ok": .double(1)])
        XCTAssertEqual(read.length, reply.count, "what follows is the next one's")
        XCTAssertNil(try MongoWire.reply(Array(reply.prefix(10))), "not all here yet")
    }

    // MARK: Connecting

    func testConnectionStrings() throws {
        let replica = try XCTUnwrap(MongoURL("mongodb://app:p%40ss:w0rd@db1:27017,db2:27018,[::1]/shop?authSource=admin&replicaSet=rs0&tls=true&tlsCAFile=%2Ftmp%2Fca.pem"))
        XCTAssertFalse(replica.srv)
        XCTAssertEqual(replica.hosts, ["db1:27017", "db2:27018", "[::1]"])
        XCTAssertEqual(replica.user, "app")
        XCTAssertEqual(replica.password, "p@ss:w0rd")
        XCTAssertEqual(replica.database, "shop")
        XCTAssertEqual(replica.authSource, "admin")
        XCTAssertTrue(replica.tls)
        XCTAssertEqual(replica.caFile, "/tmp/ca.pem")
        XCTAssertEqual(MongoURL.split("[::1]:27019").host, "::1")
        XCTAssertEqual(MongoURL.split("[::1]:27019").port, 27019)
        let atlas = try XCTUnwrap(MongoURL("mongodb+srv://ada@cluster0.ab1cd.mongodb.net/?retryWrites=true&w=majority"))
        XCTAssertTrue(atlas.srv)
        XCTAssertTrue(atlas.tls, "srv is TLS unless said otherwise")
        XCTAssertNil(atlas.password)
        XCTAssertEqual(atlas.authSource, "", "the server's TXT record, else admin")
        let docdb = try XCTUnwrap(
            MongoURL(
                "mongodb://ot:secret@sample.cluster-abc.us-east-1.docdb.amazonaws.com:27017/shop?tls=true&tlsCAFile=global-bundle.pem&replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=false"
            ))
        XCTAssertEqual(docdb.authSource, "shop", "the path's database, as the spec has it")
        XCTAssertEqual(docdb.caFile, "global-bundle.pem")
        XCTAssertEqual(docdb.options["retrywrites"], "false")
        XCTAssertFalse(try XCTUnwrap(MongoURL("mongodb://localhost")).tls)
        XCTAssertTrue(try XCTUnwrap(MongoURL("mongodb://h/?tls=true&tlsInsecure=true")).insecure)
        XCTAssertNil(MongoURL("postgres://x"))
        XCTAssertNil(MongoURL("mongodb+srv://a.b.c:27017"), "srv has no port")
        XCTAssertNil(MongoURL("mongodb+srv://a.b.c,d.e.f"), "nor several hosts")
    }

    func testAConnectionsProblems() {
        var connection = DatabaseConnection(name: "m", kind: .mongodb)
        XCTAssertEqual(connection.sslMode, .disable, "MongoDB doesn't negotiate TLS")
        XCTAssertEqual(DatabaseConnection(name: "d", kind: .documentdb).sslMode, .verifyFull, "DocumentDB's is on")
        connection.host = "a,b"
        connection.sshEnabled = true
        connection.sshHost = "bastion"
        XCTAssertNotNil(connection.problem, "a list through a tunnel")
        connection.host = "cluster.docdb.amazonaws.com"
        XCTAssertNil(connection.problem)
        connection.srv = true
        XCTAssertNotNil(connection.problem, "srv through a tunnel")
    }

    func testSCRAMAgainstTheRFCs() throws {
        // RFC 5802, 5.
        let sha1 = MongoSCRAM(mechanism: .sha1, user: "user", rawSecret: "pencil", nonce: "fyko+d2lbbFgONRv9qkxdawL")
        XCTAssertEqual(sha1.clientFirst, "n,,n=user,r=fyko+d2lbbFgONRv9qkxdawL")
        let one = try sha1.clientFinal(serverFirst: "r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096")
        XCTAssertEqual(one.message, "c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,p=v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=")
        XCTAssertNoThrow(try MongoSCRAM.verify(serverFinal: "v=rmF9pqV8S7suAoZWja4dJRkFsKQ=", expected: one.serverSignature))
        XCTAssertThrowsError(try MongoSCRAM.verify(serverFinal: "v=AAAA", expected: one.serverSignature), "a server that doesn't know the password")
        XCTAssertThrowsError(try MongoSCRAM.verify(serverFinal: "e=other-error", expected: one.serverSignature))
        // RFC 7677, 3.
        let sha256 = MongoSCRAM(mechanism: .sha256, user: "user", rawSecret: "pencil", nonce: "rOprNGfwEbeRWgbNEkqO")
        let two = try sha256.clientFinal(serverFirst: "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
        XCTAssertEqual(two.message, "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        XCTAssertNoThrow(try MongoSCRAM.verify(serverFinal: "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=", expected: two.serverSignature))
        // A nonce the client didn't start, or too few rounds: refused.
        XCTAssertThrowsError(try sha256.clientFinal(serverFirst: "r=someoneelse,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"))
        XCTAssertThrowsError(try sha256.clientFinal(serverFirst: "r=rOprNGfwEbeRWgbNEkqOx,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=1"))
        // MongoDB's SHA-1 password is its digest; a name's , and = escaped.
        XCTAssertEqual(MongoSCRAM(mechanism: .sha1, user: "user", password: "pencil", nonce: "x").secret, "1c33006ec1ffd90f9cadcbcc0e118200")
        XCTAssertEqual(MongoSCRAM(mechanism: .sha256, user: "a=b,c", password: "p", nonce: "n").clientFirstBare, "n=a=3Db=2Cc,r=n")
        XCTAssertEqual(MongoSCRAM.saslPrep("I\u{00AD}X"), "IX")
        XCTAssertEqual(MongoSCRAM.saslPrep("a\u{00A0}b"), "a b")
    }

    func testSRVRecords() {
        // priority 0, weight 0, port 27017, ac-1.ab1cd.mongodb.net.
        var rdata: [UInt8] = [0, 0, 0, 0, 0x69, 0x89]
        for label in ["ac-1", "ab1cd", "mongodb", "net"] { rdata += [UInt8(label.count)] + Array(label.utf8) }
        rdata.append(0)
        let target = MongoSRV.target(Data(rdata))
        XCTAssertEqual(target?.host, "ac-1.ab1cd.mongodb.net")
        XCTAssertEqual(target?.port, 27017)
        XCTAssertTrue(MongoSRV.sharesDomain("ac-1.ab1cd.mongodb.net", with: "cluster0.ab1cd.mongodb.net"))
        XCTAssertFalse(MongoSRV.sharesDomain("evil.example.com", with: "cluster0.ab1cd.mongodb.net"), "outside its domain")
        XCTAssertEqual(MongoSRV.strings(Data([3] + Array("a=b".utf8) + [2] + Array("cd".utf8))), ["a=b", "cd"])
    }

    func testCompletion() {
        let collections = ["orders", "order items", "users"]
        XCTAssertEqual(
            MongoCompletion.complete("db.or", collections: collections)?.candidates.map(\.insert),
            ["order items", "orders"].map {
                $0 == "orders" ? "orders." : #"getCollection("order items")."#
            })
        XCTAssertEqual(MongoCompletion.complete("db.orders.fi", collections: collections)?.candidates.map(\.label), ["find", "findOne", "findOneAndUpdate", "findOneAndDelete"])
        XCTAssertEqual(MongoCompletion.complete("db.ru", collections: collections)?.candidates.map(\.label), ["runCommand"])
        XCTAssertEqual(MongoCompletion.complete("sh", collections: [])?.candidates.map(\.label), ["show dbs", "show collections"])
        XCTAssertNil(MongoCompletion.complete("db.orders.find({ a", collections: collections))
        XCTAssertEqual(MongoText.find("orders", in: "shop", limit: 100), #"db.getSiblingDB("shop").orders.find({}).limit(100)"#)
        XCTAssertEqual(MongoText.find("a b", in: "shop", limit: 5), #"db.getSiblingDB("shop").getCollection("a b").find({}).limit(5)"#)
    }
}

/// The driver against the fake mongod (E2EMongoServer), always: the wire,
/// cursors across batches, writes said, errors as a server says them.
final class MongoFakeServerTests: XCTestCase {
    func testTheDriverOverTheWire() async throws {
        let server = E2EMongoServer()
        try server.start()
        defer { server.stop() }
        server.seed("shop", "orders", (1...250).map { ["_id": .int32(Int32($0)), "even": .bool($0 % 2 == 0)] })
        let driver = MongoDriver(server.connection(), password: nil)
        try await driver.connect()
        let page = try await driver.execute("db.orders.find({}).sort({ _id: 1 })", limit: 200)
        XCTAssertEqual(page.rows.count, 200)
        XCTAssertTrue(page.truncated)
        let all = try await driver.execute("db.orders.find({ even: true })", limit: 1000)
        XCTAssertEqual(all.rows.count, 125, "past the first batch, by getMore")
        XCTAssertEqual(server.commands.filter { $0 == "getMore" }.count, 3, "two for the page of 200, one for the 125")
        XCTAssertEqual(server.commands.filter { $0 == "killCursors" }.count, 1, "the page's cursor closed, its 50 left unread")
        let grouped = try await driver.execute(#"db.orders.aggregate([{ $group: { _id: "$even", n: { $sum: 1 } } }])"#, limit: 10)
        XCTAssertEqual(Set(grouped.rows.map { $0[1] }), ["125"])
        let deleted = try await driver.execute("db.orders.deleteMany({ even: false })", limit: 10)
        XCTAssertEqual(deleted.message, "125 deleted")
        do {
            _ = try await driver.execute("db.runCommand({ frobnicate: 1 })", limit: 10)
            XCTFail("an unknown command")
        } catch {
            XCTAssertEqual(error.localizedDescription, "no such command: 'frobnicate' (CommandNotFound)")
        }
        let schemas = try await driver.schemas()
        XCTAssertEqual(schemas, ["shop"])
        await driver.close()
        // The protocol's commands, in order: hello first, no auth without a user.
        XCTAssertEqual(server.commands.first, "hello")
        XCTAssertFalse(server.commands.contains("saslStart"))
        // A DocumentDB connection is told apart in what is said.
        var docdb = server.connection()
        docdb.kind = .documentdb
        docdb.sslMode = .disable
        let other = MongoDriver(docdb, password: nil)
        do {
            _ = try await other.execute("db.runCommand({ frobnicate: 1 })", limit: 10)
            XCTFail("an unknown command")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasSuffix("Amazon DocumentDB doesn't support this, though MongoDB does."), error.localizedDescription)
        }
        await other.close()
    }
}

/// The driver against a real mongod: `Scripts/database-test-servers.sh`'s
/// `ot-mongodb` (plain and TLS on :57017, its CA in $TMPDIR), with
/// OVERTERM_DB_TESTS=1.
@MainActor
final class MongoDriverTests: XCTestCase {
    private var servers: Bool { ProcessInfo.processInfo.environment["OVERTERM_DB_TESTS"] == "1" }

    private func connection(user: String = "ot", database: String = "shop") -> DatabaseConnection {
        var connection = DatabaseConnection(name: "mongo", kind: .mongodb)
        connection.host = "127.0.0.1"
        connection.port = 57017
        connection.user = user
        connection.database = database
        connection.authSource = "admin"
        return connection
    }

    private func failure(_ driver: MongoDriver, _ statement: String? = nil) async -> String {
        do {
            if let statement { _ = try await driver.execute(statement, limit: 10) } else { try await driver.connect() }
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    func testTheConsole() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        let driver = MongoDriver(connection(), password: "otpass")
        try await driver.connect()
        _ = try? await driver.execute("db.orders.drop()", limit: 10)
        let inserted = try await driver.execute(
            #"db.orders.insertMany([{ _id: 1, status: "open", total: NumberDecimal("9.99"), at: ISODate("2026-03-07T10:00:00Z") }, { _id: 2, status: "paid", total: 20, tags: ["a", "b"] }, { _id: 3, status: "open", customer: { name: "Ada" } }])"#,
            limit: 100)
        XCTAssertEqual(inserted.affected, 3)
        XCTAssertEqual(inserted.message, "3 inserted")
        let open = try await driver.execute(#"db.orders.find({ status: "open" }).sort({ _id: -1 })"#, limit: 100)
        XCTAssertEqual(open.columns, ["_id", "status", "customer", "total", "at"])
        XCTAssertEqual(open.rows.map { $0[0] }, ["3", "1"])
        XCTAssertEqual(open.rows[0][2], #"{ "name": "Ada" }"#)
        XCTAssertEqual(open.rows[1][3], #"NumberDecimal("9.99")"#)
        XCTAssertEqual(open.rows[1][4], "2026-03-07T10:00:00.000Z")
        XCTAssertFalse(open.truncated)
        let limited = try await driver.execute("db.orders.find({}).sort({ _id: 1 })", limit: 2)
        XCTAssertEqual(limited.rows.count, 2)
        XCTAssertTrue(limited.truncated, "more than the row limit")
        let own = try await driver.execute("db.orders.find({}).limit(1)", limit: 100)
        XCTAssertEqual(own.rows.count, 1)
        XCTAssertFalse(own.truncated, "its own limit is all it asked for")
        let one = try await driver.execute("db.orders.findOne({ _id: 2 })", limit: 100)
        XCTAssertEqual(one.rows.first?[1], "paid")
        let none = try await driver.execute("db.orders.findOne({ _id: 99 })", limit: 100)
        XCTAssertEqual(none.message, "No document matched.")
        let count = try await driver.execute(#"db.orders.countDocuments({ status: "open" })"#, limit: 100)
        XCTAssertEqual(count.rows, [["2"]])
        let grouped = try await driver.execute(#"db.orders.aggregate([{ $group: { _id: "$status", n: { $sum: 1 } } }, { $sort: { _id: 1 } }])"#, limit: 100)
        XCTAssertEqual(grouped.rows, [["open", "2"], ["paid", "1"]])
        let distinct = try await driver.execute("db.orders.distinct('status')", limit: 100)
        XCTAssertEqual(Set(distinct.rows.compactMap { $0[0] }), ["open", "paid"])
        let updated = try await driver.execute(#"db.orders.updateMany({ status: "open" }, { $set: { seen: true } })"#, limit: 100)
        XCTAssertEqual(updated.message, "2 matched, 2 modified")
        let upserted = try await driver.execute("db.orders.updateOne({ _id: 9 }, { $set: { status: 'new' } }, { upsert: true })", limit: 100)
        XCTAssertEqual(upserted.affected, 1)
        let modified = try await driver.execute("db.orders.findOneAndUpdate({ _id: 9 }, { $inc: { n: 1 } }, { returnDocument: 'after' })", limit: 100)
        XCTAssertEqual(modified.rows.first?.last ?? nil, "1")
        let deleted = try await driver.execute("db.orders.deleteOne({ _id: 9 })", limit: 100)
        XCTAssertEqual(deleted.affected, 1)
        let duplicate = await failure(driver, "db.orders.insertOne({ _id: 1 })")
        XCTAssertTrue(duplicate.contains("duplicate key"), duplicate)
        let bad = await failure(driver, "db.orders.find({ $nope: 1 })")
        XCTAssertTrue(bad.contains("$nope"), bad)
        let ping = try await driver.execute("db.runCommand({ ping: 1 })", limit: 100)
        XCTAssertEqual(ping.message, "Done", "ok alone is nothing to show")
        let build = try await driver.execute("db.runCommand({ buildInfo: 1 })", limit: 100)
        XCTAssertTrue(build.rows.contains { $0[0] == "version" })
        let collections = try await driver.execute("show collections", limit: 100)
        XCTAssertTrue(collections.rows.contains { $0[0] == "orders" })
        let databases = try await driver.execute("show dbs", limit: 100)
        XCTAssertTrue(databases.rows.contains { $0[0] == "shop" })
        _ = try await driver.execute("db.getSiblingDB('other').things.insertOne({ a: 1 })", limit: 10)
        _ = try await driver.execute("use other", limit: 10)
        let elsewhere = try await driver.execute("db.things.countDocuments({})", limit: 10)
        XCTAssertEqual(elsewhere.rows, [["1"]], "use moved db")
        _ = try await driver.execute("db.dropDatabase()", limit: 10)
        // The catalog: databases, collections, a sample's fields.
        let schemas = try await driver.schemas()
        XCTAssertTrue(schemas.contains("shop"), "\(schemas)")
        XCTAssertFalse(schemas.contains("admin"), "the system's own left out")
        let tables = try await driver.tables(in: "shop")
        XCTAssertTrue(tables.contains { $0.name == "orders" }, "\(tables)")
        let fields = try await driver.columns(in: "shop").filter { $0.table == "orders" }
        XCTAssertEqual(fields.first?.name, "_id")
        XCTAssertTrue(fields.contains { $0.name == "customer" && $0.type == "object" }, "\(fields)")
        _ = try await driver.execute("db.orders.drop()", limit: 10)
        await driver.close()
    }

    func testAPageAcrossBatches() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        let driver = MongoDriver(connection(), password: "otpass")
        try await driver.connect()
        _ = try? await driver.execute("db.big.drop()", limit: 10)
        // 2,000 documents of 10 KB: more than a 16 MB batch holds, so getMore runs.
        let padding = String(repeating: "x", count: 10_000)
        for chunk in 0..<4 {
            let documents = (0..<500).map { "{ _id: \(chunk * 500 + $0), pad: \"\(padding)\" }" }.joined(separator: ", ")
            _ = try await driver.execute("db.big.insertMany([\(documents)])", limit: 10)
        }
        let all = try await driver.execute("db.big.aggregate([{ $sort: { _id: 1 } }])", limit: 1900)
        XCTAssertEqual(all.rows.count, 1900)
        XCTAssertTrue(all.truncated)
        XCTAssertEqual(all.rows.last?[0], "1899")
        let rest = try await driver.execute("db.big.find({}).sort({ _id: 1 }).skip(1990)", limit: 1900)
        XCTAssertEqual(rest.rows.count, 10)
        XCTAssertFalse(rest.truncated)
        _ = try await driver.execute("db.big.drop()", limit: 10)
        await driver.close()
    }

    func testSigningIn() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        let wrong = await failure(MongoDriver(connection(), password: "nope"))
        XCTAssertTrue(wrong.hasPrefix("Authentication failed"), wrong)
        XCTAssertTrue(wrong.contains("admin"), "the auth database said: \(wrong)")
        let elsewhere = connection()
        var shopAuth = elsewhere
        shopAuth.authSource = "shop"
        let misplaced = await failure(MongoDriver(shopAuth, password: "otpass"))
        XCTAssertTrue(misplaced.contains("auth database shop"), misplaced)
        let none = await failure(MongoDriver(connection(), password: nil))
        XCTAssertTrue(
            DatabaseSession.explain(DatabaseError.failed(none), passwordGiven: false, readProblem: nil).contains("none is saved"), none)
        // A user with SCRAM-SHA-1 alone, as DocumentDB's and older servers' are.
        let admin = MongoDriver(connection(), password: "otpass")
        try await admin.connect()
        _ = try? await admin.execute("db.getSiblingDB('admin').runCommand({ dropUser: 'otsha1' })", limit: 10)
        _ = try await admin.execute(
            "db.getSiblingDB('admin').runCommand({ createUser: 'otsha1', pwd: 'otpass', roles: ['readAnyDatabase'], mechanisms: ['SCRAM-SHA-1'] })",
            limit: 10)
        let sha1 = MongoDriver(connection(user: "otsha1"), password: "otpass")
        try await sha1.connect()
        let read = try await sha1.execute("db.runCommand({ ping: 1 })", limit: 10)
        XCTAssertEqual(read.message, "Done")
        await sha1.close()
        _ = try await admin.execute("db.getSiblingDB('admin').runCommand({ dropUser: 'otsha1' })", limit: 10)
        await admin.close()
        // Nobody answering: said, not hung.
        var nowhere = connection()
        nowhere.port = 1
        let unreachable = await failure(MongoDriver(nowhere, password: "otpass"))
        XCTAssertTrue(unreachable.hasPrefix("Couldn't reach MongoDB at 127.0.0.1:1"), unreachable)
    }

    func testReadOnlyRefusesBeforeSending() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        var readOnly = connection()
        readOnly.readOnly = true
        let driver = MongoDriver(readOnly, password: "otpass")
        try await driver.connect()
        let refused = await failure(driver, "db.orders.insertOne({ a: 1 })")
        XCTAssertEqual(refused, DatabaseError.readOnly("insertOne").localizedDescription)
        let out = await failure(driver, "db.orders.aggregate([{ $out: 'copy' }])")
        XCTAssertTrue(out.contains("only reads"), out)
        _ = try await driver.execute("db.orders.find({})", limit: 10)
        await driver.close()
    }

    func testTLS() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        let ca =
            ProcessInfo.processInfo.environment["OVERTERM_MONGO_CA"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("ot-mongodb-tls/ca.pem")
        guard FileManager.default.fileExists(atPath: ca) else { throw XCTSkip("no test CA at \(ca)") }
        var encrypted = connection()
        encrypted.host = "localhost"
        encrypted.sslMode = .require
        let unchecked = MongoDriver(encrypted, password: "otpass")
        try await unchecked.connect()
        await unchecked.close()
        // Verified: against its own CA, as DocumentDB's bundle is chosen.
        encrypted.sslMode = .verifyFull
        encrypted.caFile = ca
        let verified = MongoDriver(encrypted, password: "otpass")
        try await verified.connect()
        let ping = try await verified.execute("db.runCommand({ ping: 1 })", limit: 1)
        XCTAssertEqual(ping.message, "Done")
        await verified.close()
        // Without it, the system doesn't know the CA: refused, and said why.
        encrypted.caFile = ""
        let untrusted = await failure(MongoDriver(encrypted, password: "otpass"))
        XCTAssertTrue(untrusted.contains("isn't trusted"), untrusted)
        encrypted.caFile = "/nonexistent/ca.pem"
        let missing = await failure(MongoDriver(encrypted, password: "otpass"))
        XCTAssertTrue(missing.contains("can't be read"), missing)
    }
}
