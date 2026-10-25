import XCTest

@testable import Overterm

/// SigV4 against AWS's own documented examples (Signature Version 4,
/// "Examples: Signature Calculations in AWS Signature Version 4").
final class S3SignerTests: XCTestCase {
    private let signer = S3Signer(
        accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", sessionToken: nil, region: "us-east-1")
    private let date = ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z")!

    func testGetObjectWithARange() {
        let headers = signer.sign(
            method: "GET", url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!, headers: ["Range": "bytes=0-9"],
            payloadHash: S3Signer.sha256(Data()), date: date)
        XCTAssertEqual(
            headers["Authorization"],
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        )
        XCTAssertEqual(headers["x-amz-date"], "20130524T000000Z")
    }

    func testAPresignedURL() {
        let url = signer.presign(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!, expires: 86400, date: date)
        XCTAssertTrue(
            url?.absoluteString.hasSuffix("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404") == true,
            url?.absoluteString ?? "-")
    }

    func testKeysAreEncodedOnceInThePath() {
        XCTAssertEqual(S3Signer.canonicalPath(URL(string: "https://h/b/My%20Folder/a+b.txt")!), "/b/My%20Folder/a%2Bb.txt")
        XCTAssertEqual(
            S3Signer.canonicalQuery(URL(string: "https://h/b?prefix=a%2F&list-type=2&delimiter=%2F")!),
            "delimiter=%2F&list-type=2&prefix=a%2F")
    }
}
