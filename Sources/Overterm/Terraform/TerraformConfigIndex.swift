import Foundation

/// A module's definitions — its `.tf` files' blocks by address — for F12
/// and ⇧⌘O where terraform-ls isn't running (analysis 4.14): `var.x` to
/// its `variable "x"`, `local.x` to its line in `locals`, `module.y`,
/// `data.t.n`, `t.n`. Pure, over the texts it is given (the open buffers'
/// over the files on disk, by the caller).
struct TerraformConfigIndex: Sendable {
    struct Definition: Equatable, Sendable {
        /// `var.region`, `local.tags`, `module.net`, `aws_s3_bucket.logs`, `data.aws_ami.ubuntu`, `output.url`.
        var address: String
        /// `variable`, `local`, `module`, `resource`, `data`, `output`, `provider`…: what ⇧⌘O's badge says.
        var kind: String
        var file: URL
        /// The name, to select; the whole block or line, for the outline.
        var nameRange: NSRange
        var range: NSRange
    }

    private(set) var definitions: [String: Definition] = [:]

    /// The files of a module: its folder's `.tf` and `.tofu` files.
    static func isModuleFile(_ url: URL) -> Bool {
        ["tf", "tofu"].contains(url.pathExtension.lowercased())
    }

    init(files: [(url: URL, text: String)]) {
        // Sorted, so a name defined twice (an error terraform reports) resolves the same way every time.
        for file in files.sorted(by: { $0.url.path < $1.url.path }) {
            for definition in Self.definitions(in: file.text, file: file.url) where definitions[definition.address] == nil {
                definitions[definition.address] = definition
            }
        }
    }

    func definition(of address: String) -> Definition? { definitions[address] }

    // MARK: A folder's

    /// Bounds on what `load` reads from disk: a module is tens of files, and
    /// a folder of generated ones isn't read whole — 500 names, 2 MB a
    /// file, 8 MB in all.
    static let fileLimit = 500
    static let fileByteLimit = 2 << 20
    static let byteLimit = 8 << 20

    /// A module's index from its folder: `open`'s texts (the open buffers,
    /// by standardized path) as they are on screen, the rest from disk
    /// within the bounds. Blocking: a GCD thread's, never the main one.
    static func load(folder: URL, open: [String: String], byteLimit: Int = byteLimit) -> TerraformConfigIndex {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var files: [(url: URL, text: String)] = []
        var budget = byteLimit
        for name in names.sorted().prefix(fileLimit) {
            let url = folder.appendingPathComponent(name)
            guard isModuleFile(url) else { continue }
            if let text = open[url.standardizedFileURL.path] {
                files.append((url, text))
                continue
            }
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size <= fileByteLimit, size <= budget,
                let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            budget -= size
            files.append((url, text))
        }
        return TerraformConfigIndex(files: files)
    }

    /// `address`'s definition in `folder`'s module, read and parsed off
    /// the main thread.
    static func loadDefinition(of address: String, in folder: URL, open: [String: String]) async -> Definition? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Definition?, Never>) in
            let work: @Sendable () -> Void = { continuation.resume(returning: load(folder: folder, open: open).definition(of: address)) }
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
    }

    /// A file's definitions, in order: its blocks, a `locals` block's names
    /// each its own, a `.tfvars` file's assignments as the variables they set.
    static func definitions(in text: String, file: URL) -> [Definition] {
        let scanned = TerraformBlocks.scan(text)
        var found: [Definition] = []
        for block in scanned.blocks {
            if block.type == "locals" {
                for attribute in block.attributes {
                    found.append(
                        Definition(address: "local.\(attribute.name)", kind: "local", file: file, nameRange: attribute.nameRange, range: attribute.nameRange))
                }
                continue
            }
            guard let address = address(of: block) else { continue }
            found.append(Definition(address: address, kind: block.type, file: file, nameRange: block.nameRange, range: block.range))
        }
        for attribute in scanned.attributes {
            found.append(Definition(address: "tfvars.\(attribute.name)", kind: "variable", file: file, nameRange: attribute.nameRange, range: attribute.nameRange))
        }
        return found
    }

    /// The address a block defines, as a reference names it.
    static func address(of block: TerraformBlocks.Block) -> String? {
        let labels = block.labels
        switch block.type {
        case "variable": return labels.count == 1 ? "var.\(labels[0])" : nil
        case "module", "output": return labels.count == 1 ? "\(block.type).\(labels[0])" : nil
        case "resource": return labels.count == 2 ? "\(labels[0]).\(labels[1])" : nil
        case "data", "ephemeral", "list", "action": return labels.count == 2 ? "\(block.type).\(labels[0]).\(labels[1])" : nil
        case "provider": return labels.count == 1 ? "provider.\(labels[0])" : nil
        case "terraform", "moved", "import", "removed", "check", "locals": return labels.isEmpty ? block.type : nil
        default: return nil
        }
    }

    // MARK: What the caret is on

    /// The address of the reference around `index` in `text` — `var.x`,
    /// `local.x`, `module.y`, `data.t.n`, `t.n` — or nil when it names
    /// nothing a module defines (`each.key`, `path.module`, a string). In
    /// a `.tfvars` file, an assignment's name is the variable it sets.
    static func reference(at index: Int, in text: String, tfvars: Bool = false) -> String? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        func isPart(_ c: unichar) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x2D || c == 0x2E
        }
        var start = min(max(0, index), ns.length)
        var end = start
        while start > 0, isPart(ns.character(at: start - 1)) { start -= 1 }
        while end < ns.length, isPart(ns.character(at: end)) { end += 1 }
        guard end > start else { return nil }
        let word = ns.substring(with: NSRange(location: start, length: end - start))
        let parts = word.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let head = parts.first, !head.isEmpty else { return nil }
        if tfvars, parts.count == 1 { return "var.\(head)" }
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        switch head {
        case "var": return "var.\(parts[1])"
        case "local": return "local.\(parts[1])"
        case "module": return "module.\(parts[1])"
        case "data", "ephemeral":
            return parts.count >= 3 && !parts[2].isEmpty ? "\(head).\(parts[1]).\(parts[2])" : nil
        case "each", "count", "path", "terraform", "self":
            return nil
        default:
            // A resource: `aws_s3_bucket.logs.arn`. A type has an underscore
            // (its provider's prefix) or is one of the builtins.
            guard head.contains("_") || head == "terraform_data" else { return nil }
            return "\(head).\(parts[1])"
        }
    }
}
