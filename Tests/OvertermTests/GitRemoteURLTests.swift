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

    // MARK: The repository a URL names (4.2)

    func testEveryWayOfWritingARepositoryComparesEqual() throws {
        let shop = GitRemoteURL(host: "git.acme.example", path: "acme/shop")
        let forms = [
            "https://git.acme.example/acme/shop.git", "https://git.acme.example/acme/shop/", "  https://git.acme.example/acme/shop.git/  ",
            "http://git.acme.example/acme/shop", "https://user:ghp_fake@git.acme.example/acme/shop.git", "https://ghp_fake@git.acme.example:443/acme/shop",
            "git@git.acme.example:acme/shop.git", "ssh://git@git.acme.example:2222/acme/shop.git", "git+ssh://git@git.acme.example/acme/shop",
            "ssh+git://git.acme.example/acme/shop", "git://git.acme.example/acme/shop.git", "HTTPS://GIT.ACME.EXAMPLE/acme/shop",
        ]
        for form in forms {
            let url = try XCTUnwrap(GitRemoteURL(form), form)
            XCTAssertEqual(url, shop, form)
            XCTAssertEqual(url.description, "git.acme.example/acme/shop", form)
            XCTAssertFalse(url.description.contains("ghp_fake"))
        }
        XCTAssertNotEqual(GitRemoteURL("https://git.acme.example/Acme/Shop"), shop, "a self-hosted path compares exactly")
        XCTAssertNotEqual(GitRemoteURL("https://git.acme.example:8443/acme/shop"), shop, "not a default port: another server")
    }

    func testHostsTheirOwnWay() {
        XCTAssertEqual(GitRemoteURL("https://ghp_x@github.com/acme/shop.git")?.description, "github.com/acme/shop")
        XCTAssertEqual(GitRemoteURL("https://oauth2:tok@gitlab.com/acme/group/sub/shop.git")?.description, "gitlab.com/acme/group/sub/shop", "subgroups whole")
        XCTAssertEqual(GitRemoteURL("https://github.com/Acme/Shop"), GitRemoteURL("git@github.com:acme/shop.git"), "GitHub's paths ignore case")
        XCTAssertEqual(GitRemoteURL("ssh://git@ssh.github.com:443/acme/shop.git"), GitRemoteURL("https://github.com/acme/shop"))
        XCTAssertEqual(GitRemoteURL("ssh://git@altssh.gitlab.com:443/acme/shop.git"), GitRemoteURL("https://gitlab.com/acme/shop"))
        XCTAssertEqual(GitRemoteURL("https://bitbucket.org/Acme/shop"), GitRemoteURL("git@bitbucket.org:acme/shop.git"))
        // Azure DevOps' three forms.
        let azure = GitRemoteURL(host: "dev.azure.com", path: "acme/shop/shop-api")
        XCTAssertEqual(GitRemoteURL("https://dev.azure.com/acme/shop/_git/shop-api"), azure)
        XCTAssertEqual(GitRemoteURL("https://acme@dev.azure.com/acme/shop/_git/shop-api"), azure)
        XCTAssertEqual(GitRemoteURL("git@ssh.dev.azure.com:v3/acme/shop/shop-api"), azure)
        XCTAssertEqual(GitRemoteURL("https://acme.visualstudio.com/shop/_git/shop-api"), azure)
        XCTAssertEqual(GitRemoteURL("https://acme.visualstudio.com/DefaultCollection/shop/_git/shop-api"), azure)
        // An ssh alias is compared as written.
        XCTAssertEqual(GitRemoteURL("acme-git:acme/shop.git")?.host, "acme-git")
    }

    func testWhatNamesNoRepository() {
        XCTAssertNil(GitRemoteURL("oci://ghcr.io/acme/charts"), "oci never matches a checkout")
        XCTAssertNil(GitRemoteURL("s3://acme-bucket/manifests"))
        XCTAssertNil(GitRemoteURL("/srv/git/shop.git"), "a local path")
        XCTAssertNil(GitRemoteURL("./shop"))
        XCTAssertNil(GitRemoteURL(""))
        XCTAssertNil(GitRemoteURL("https://git.acme.example/"), "no path")
        XCTAssertNil(GitRemoteURL("https://git.acme.example/acme\u{0}/shop"))
    }

    /// `git remote -v`'s raw output, a token from `url.*.insteadOf` in it,
    /// never leaves the parser.
    func testRemotesNeverCarryARawURL() {
        let output = """
            origin\thttps://bot:ghp_fake@git.acme.example/acme/shop.git\t(fetch)
            origin\thttps://bot:ghp_fake@git.acme.example/acme/shop.git\t(push)
            mirror\tgit@git.acme.example:acme/shop.git\t(fetch)
            """
        let remotes = Refs.parse(remotes: output)
        XCTAssertEqual(remotes.map(\.url), ["https://git.acme.example/acme/shop.git", "git@git.acme.example:acme/shop.git"])
        XCTAssertFalse(remotes.contains { $0.url.contains("ghp_fake") })
        XCTAssertEqual(remotes[0].repo, remotes[1].repo, "one repository, two ways")
        XCTAssertEqual(remotes[0].host, "git.acme.example")
    }
}
