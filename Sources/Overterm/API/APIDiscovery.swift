import Foundation

/// What the API panel can start from when the checkout has no collection —
/// or wants another: an OpenAPI document, a Postman collection or a .http
/// file in the checkout, and an API a tab is serving, found by asking its
/// ports where frameworks publish their OpenAPI document.
enum APIDiscovery {
    enum Source: Equatable, Hashable, Identifiable, Sendable {
        case file(URL, kind: Kind)
        /// `spec` answered with an OpenAPI document titled `title`; `base` is the server.
        case server(base: URL, spec: URL, title: String)

        var id: String {
            switch self {
            case .file(let url, _): url.path
            case .server(_, let spec, _): spec.absoluteString
            }
        }

        var title: String {
            switch self {
            case .file(let url, let kind): "\(kind.title): \(url.lastPathComponent)"
            case .server(let base, _, let title): "\(title) on \(base.host ?? "localhost"):\(base.port.map(String.init) ?? "")"
            }
        }
    }

    enum Kind: String, Sendable {
        case openAPI, postman, http
        var title: String {
            switch self {
            case .openAPI: "OpenAPI"
            case .postman: "Postman"
            case .http: "HTTP file"
            }
        }
    }

    /// Where frameworks serve their document: FastAPI, Springdoc, NestJS,
    /// ASP.NET (Swashbuckle), Express's swagger-jsdoc setups, Rails' rswag.
    static let specPaths = [
        "/openapi.json", "/v3/api-docs", "/swagger.json", "/api-docs", "/swagger/v1/swagger.json", "/api/openapi.json",
        "/docs/openapi.json", "/api-docs.json", "/openapi.yaml", "/api/swagger.json",
    ]

    static func find(in root: URL, ports: [Int], probe: Bool) async -> [Source] {
        let files = await Task.detached(priority: .utility) { findFiles(in: root) }.value
        let servers = probe ? await probeServers(ports) : []
        return servers + files
    }

    /// Files in the checkout, at most `depth` folders down, not in
    /// dependency or build folders.
    static func findFiles(in root: URL, depth: Int = 4) -> [Source] {
        var found: [Source] = []
        let skipped: Set<String> = ["node_modules", "build", "dist", "target", "vendor", "Pods", "DerivedData", ".git", "bruno"]
        func walk(_ folder: URL, _ level: Int) {
            guard found.count < 20,
                let children = try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])
            else { return }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = child.lastPathComponent
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    // Inside a collection there is nothing to import.
                    if level < depth, !skipped.contains(name),
                        !FileManager.default.fileExists(atPath: child.appendingPathComponent(BrunoCollection.configName).path)
                    {
                        walk(child, level + 1)
                    }
                    continue
                }
                guard (values?.fileSize ?? 0) < 20_000_000, let kind = kind(of: child) else { continue }
                found.append(.file(child, kind: kind))
            }
        }
        walk(root.standardizedFileURL, 0)
        return found
    }

    /// By name first; a JSON or YAML file only if its start says what it is.
    static func kind(of url: URL) -> Kind? {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if ext == "http" || ext == "rest" { return .http }
        if name.hasSuffix(".postman_collection.json") { return .postman }
        guard ["json", "yaml", "yml"].contains(ext) else { return nil }
        let base = (name as NSString).deletingPathExtension
        let named = base == "openapi" || base == "swagger" || base.hasSuffix(".openapi") || base.hasSuffix("-openapi") || base == "api-docs"
        guard named, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 4096), as: UTF8.self)
        return head.contains("openapi") || head.contains("swagger") ? .openAPI : nil
    }

    /// Each port asked at the usual paths, all at once, a second each.
    static func probeServers(_ ports: [Int]) async -> [Source] {
        let unique = Array(Set(ports)).sorted().prefix(12)
        guard !unique.isEmpty else { return [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return await withTaskGroup(of: Source?.self) { group in
            for port in unique {
                group.addTask {
                    guard let base = URL(string: "http://localhost:\(port)") else { return nil }
                    for path in specPaths {
                        guard let spec = URL(string: base.absoluteString + path),
                            let (data, response) = try? await session.data(from: spec),
                            (response as? HTTPURLResponse)?.statusCode == 200,
                            let document = APIImport.parseDocument(data), OpenAPIImporter.isOpenAPI(document)
                        else { continue }
                        let title = ((document["info"] as? [String: Any])?["title"] as? String) ?? "An API"
                        return .server(base: base, spec: spec, title: title)
                    }
                    return nil
                }
            }
            var found: [Source] = []
            for await source in group { if let source { found.append(source) } }
            return found.sorted { $0.id < $1.id }
        }
    }
}
