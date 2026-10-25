import XCTest

@testable import Overterm

/// The storage clients: S3's XML read offline, the AWS CLI's profiles,
/// and the whole round trip against an S3 server (RustFS, in Docker) when
/// OVERTERM_DB_TESTS=1.
final class StorageClientTests: XCTestCase {
    func testAListingsFoldersFilesAndNextPage() {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ListBucketResult><Name>b</Name><Prefix>logs/</Prefix><IsTruncated>true</IsTruncated>
            <NextContinuationToken>abc</NextContinuationToken>
            <Contents><Key>logs/</Key><Size>0</Size></Contents>
            <Contents><Key>logs/a &amp; b.txt</Key><LastModified>2026-03-07T09:05:01.000Z</LastModified><ETag>"e1"</ETag><Size>42</Size></Contents>
            <CommonPrefixes><Prefix>logs/2026/</Prefix></CommonPrefixes>
            </ListBucketResult>
            """
        let listing = S3Client.listing(Data(xml.utf8), prefix: "logs/")
        XCTAssertEqual(listing.folders, ["logs/2026/"])
        XCTAssertEqual(listing.objects.map(\.key), ["logs/a & b.txt"], "the folder's own marker isn't a file")
        XCTAssertEqual(listing.objects.first?.size, 42)
        XCTAssertEqual(listing.objects.first?.etag, "e1")
        XCTAssertEqual(listing.objects.first?.name, "a & b.txt")
        XCTAssertEqual(listing.next, "abc")
        XCTAssertNotNil(listing.objects.first?.modified)
    }

    func testAWSProfilesAreReadAsTheCLIReadsThem() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aws-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".aws"), withIntermediateDirectories: true)
        try "[default]\naws_access_key_id = AK1\naws_secret_access_key = S1\n\n[work]\naws_access_key_id=AK2\naws_secret_access_key=S2\naws_session_token=T2\n"
            .write(to: home.appendingPathComponent(".aws/credentials"), atomically: true, encoding: .utf8)
        try "[default]\nregion = eu-west-1\n[profile work]\nregion=us-west-2\n".write(
            to: home.appendingPathComponent(".aws/config"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AWSProfile.load("", home: home), .init(accessKey: "AK1", secretKey: "S1", sessionToken: nil, region: "eu-west-1"))
        XCTAssertEqual(AWSProfile.load("work", home: home), .init(accessKey: "AK2", secretKey: "S2", sessionToken: "T2", region: "us-west-2"))
        XCTAssertNil(AWSProfile.load("nope", home: home))
        XCTAssertEqual(AWSProfile.names(home: home), ["default", "work"])
    }

    func testAnS3Server() async throws {
        guard ProcessInfo.processInfo.environment["OVERTERM_DB_TESTS"] == "1" else {
            throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh")
        }
        var connection = DatabaseConnection(name: "MinIO", kind: .s3)
        connection.apply(.minio)
        connection.host = "127.0.0.1"
        connection.port = 59000
        connection.user = "otadmin"
        let client = S3Client(connection, secret: "otpass12345")
        let bucket = "ot-test-\(UInt32.random(in: 0...UInt32.max))"
        try await client.createBucket(bucket)
        try await client.connect()
        let buckets = try await client.buckets()
        XCTAssertTrue(buckets.contains { $0.name == bucket }, "\(buckets)")

        try await client.put(bucket: bucket, key: "hello.txt", data: Data("hello, world".utf8), contentType: "text/plain")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ot-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: file) }
        try "id,name\n1,a\n2,b\n".write(to: file, atomically: true, encoding: .utf8)
        let progress = Progressed()
        try await client.upload(bucket: bucket, key: "data/My Report.csv", file: file, contentType: "text/csv") { progress.last = $0 }
        XCTAssertEqual(progress.last, 1, "upload reports its progress")

        let root = try await client.list(bucket: bucket, prefix: "", after: nil)
        XCTAssertEqual(root.folders, ["data/"])
        XCTAssertEqual(root.objects.map(\.key), ["hello.txt"])
        let data = try await client.list(bucket: bucket, prefix: "data/", after: nil)
        XCTAssertEqual(data.objects.map(\.name), ["My Report.csv"], "a name with a space")
        let part = try await client.read(bucket: bucket, key: "hello.txt", range: 0...4)
        XCTAssertEqual(String(decoding: part, as: UTF8.self), "hello")
        let meta = try await client.head(bucket: bucket, key: "data/My Report.csv")
        XCTAssertEqual(meta.size, 16)
        XCTAssertEqual(meta.contentType, "text/csv")

        // A presigned link opens without the key.
        let link = try await client.link(bucket: bucket, key: "hello.txt", expires: 60)
        let (body, response) = try await URLSession.shared.data(from: XCTUnwrap(link))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello, world")

        // A folder goes with everything in it.
        let keys = try await client.keys(bucket: bucket, prefix: "data/")
        XCTAssertEqual(keys, ["data/My Report.csv"])
        try await client.delete(bucket: bucket, keys: keys + ["hello.txt"])
        let empty = try await client.list(bucket: bucket, prefix: "", after: nil)
        XCTAssertTrue(empty.folders.isEmpty && empty.objects.isEmpty)

        // A wrong secret is said plainly.
        do {
            _ = try await S3Client(connection, secret: "wrong").buckets()
            XCTFail("listed with a wrong secret")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("secret key"), error.localizedDescription)
        }
    }
}

private final class Progressed: @unchecked Sendable {
    var last: Double = 0
}
