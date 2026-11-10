import XCTest

@testable import Overterm

/// A git remote's URL without the credentials it can carry: the whole
/// userinfo, a token with no `:` too, cut at the authority's last `@`;
/// an `@` in the path, the scp form and text without a URL left as they
/// are (docs/design/kubernetes/gitops.md, 4.2 and 5.3).
final class GitRemoteURLTests: XCTestCase {
    func testAURLLosesItsWholeUserinfo() {
        XCTAssertEqual(GitRemoteURL.withoutUserinfo("https://user:ghp_fake@git.acme.example/acme/shop.git"), "https://git.acme.example/acme/shop.git")
        XCTAssertEqual(GitRemoteURL.withoutUserinfo("https://ghp_fake@github.com/acme/shop.git"), "https://github.com/acme/shop.git", "a token with no colon")
        XCTAssertEqual(GitRemoteURL.withoutUserinfo("https://oauth2:tok@gitlab.com/acme/group/shop"), "https://gitlab.com/acme/group/shop")
        XCTAssertEqual(GitRemoteURL.withoutUserinfo("oci://robot:s3cr3t@ghcr.io/acme/charts"), "oci://ghcr.io/acme/charts", "any scheme")
        XCTAssertEqual(GitRemoteURL.withoutUserinfo("ssh://git@git.acme.example:2222/acme/shop.git"), "ssh://git.acme.example:2222/acme/shop.git")
        XCTAssertEqual(GitRemoteURL.withoutUserinfo("https://bot:p@ss@git.acme.example/x"), "https://git.acme.example/x", "a raw @ in the password goes too")
        XCTAssertEqual(GitRemoteURL.withoutUserinfo("https://:tok@git.acme.example/x"), "https://git.acme.example/x", "no user")
        XCTAssertEqual(GitRemoteURL.withoutUserinfo("https://git.acme.example:8443/x?ref=a#b"), "https://git.acme.example:8443/x?ref=a#b", "the port stays")
    }

    func testWhatHoldsNoCredentialIsLeftAsWritten() {
        XCTAssertEqual(
            GitRemoteURL.withoutUserinfo("http://api.acme.example:8080/users/jane@example.com"), "http://api.acme.example:8080/users/jane@example.com",
            "an @ in the path")
        XCTAssertEqual(GitRemoteURL.withoutUserinfo("https://git.acme.example/x?by=jane@example.com"), "https://git.acme.example/x?by=jane@example.com")
        XCTAssertEqual(GitRemoteURL.withoutUserinfo("git@git.acme.example:acme/shop.git"), "git@git.acme.example:acme/shop.git", "scp form: a user, no secret")
        XCTAssertEqual(GitRemoteURL.withoutUserinfo("jane@example.com"), "jane@example.com")
        XCTAssertEqual(GitRemoteURL.withoutUserinfo("not a url://x@y"), "not a url://x@y", "no scheme before ://")
        XCTAssertEqual(GitRemoteURL.withoutUserinfo(""), "")
    }

    func testEveryURLInTextLosesItsUserinfo() {
        XCTAssertEqual(
            GitRemoteURL.stripUserinfo(inText: "failed to checkout 'https://bot:ghp_fake@git.acme.example/acme/shop.git': auth"),
            "failed to checkout 'https://git.acme.example/acme/shop.git': auth")
        XCTAssertEqual(GitRemoteURL.stripUserinfo(inText: "a https://tok@h/x and oci://u:p@r/c"), "a https://h/x and oci://r/c", "every URL")
        XCTAssertEqual(GitRemoteURL.stripUserinfo(inText: "from https://u:p@ss@h/x"), "from https://h/x", "the authority's last @")
        XCTAssertEqual(GitRemoteURL.stripUserinfo(inText: "mail jane@example.com, see https://h/x"), "mail jane@example.com, see https://h/x")
        XCTAssertEqual(GitRemoteURL.stripUserinfo(inText: "http://api:8080/users/jane@example.com"), "http://api:8080/users/jane@example.com")
    }
}
