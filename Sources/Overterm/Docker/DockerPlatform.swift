import Foundation

/// What an image is built for, or what an engine runs on, as Docker says a
/// platform: `linux/amd64`, `linux/arm/v7`. Pure.
struct DockerPlatform: Hashable, Sendable, CustomStringConvertible {
    var os: String
    /// Go's names, as images say them: amd64, arm64, arm, 386, ppc64le,
    /// s390x, riscv64.
    var architecture: String
    /// arm's v7 and v6; nil for the others, whose variants (arm64's v8,
    /// amd64's v2 and v3) don't change what runs them.
    var variant: String?

    init(architecture: String, variant: String? = nil, os: String = "linux") {
        self.os = os
        self.architecture = architecture
        self.variant = variant
    }

    /// An image's inspect data (`Os`, `Architecture`, `Variant`). Nil when
    /// it says no architecture. arm64's `v8` is dropped, as containerd
    /// drops it: an index says `arm64/v8` and an image `arm64`.
    init?(os: String?, architecture: String?, variant: String?) {
        guard let architecture = architecture?.lowercased(), !architecture.isEmpty else { return nil }
        let os = os.flatMap { $0.isEmpty ? nil : $0.lowercased() } ?? "linux"
        let variant = variant.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        self.init(architecture: architecture, variant: ["arm64", "amd64"].contains(architecture) ? nil : variant, os: os)
    }

    /// The engine's, from `/info`: its `Architecture` is the host's
    /// `uname -m` (aarch64, x86_64), its `OSType` Go's (linux).
    init?(engine machine: String?, os: String? = "linux") {
        guard let machine = machine?.lowercased(), !machine.isEmpty else { return nil }
        let (architecture, variant): (String, String?) =
            switch machine {
            case "x86_64", "amd64": ("amd64", nil)
            case "aarch64", "arm64": ("arm64", nil)
            case "armv7l", "armv7": ("arm", "v7")
            case "armv6l", "armv6": ("arm", "v6")
            case "i386", "i686": ("386", nil)
            default: (machine, nil)
            }
        self.init(architecture: architecture, variant: variant, os: os.flatMap { $0.isEmpty ? nil : $0.lowercased() } ?? "linux")
    }

    /// `linux/arm/v7`, as `--platform` takes it.
    var description: String { ([os, architecture] + [variant].compactMap { $0 }).joined(separator: "/") }

    /// `arm/v7`: what a badge says.
    var short: String { ([architecture] + [variant].compactMap { $0 }).joined(separator: "/") }

    /// Whether `engine` runs it without translating: the same architecture,
    /// or 32-bit x86 on amd64.
    func runsNatively(on engine: DockerPlatform) -> Bool {
        architecture == engine.architecture || (architecture == "386" && engine.architecture == "amd64")
    }

    /// The name its image can be pulled by: the list's, unless the list
    /// says the image's id — its tag has moved on (a pull, a build) —
    /// when only inspect's `reference` (`Config.Image`) names it. Nil
    /// when nothing does.
    static func nameToPull(_ container: ContainerSummary, reference: String? = nil) -> String? {
        let image = container.Image
        let id = (container.ImageID ?? "").replacingOccurrences(of: "sha256:", with: "")
        let byID = DockerClient.listsImageByID(container) || (image.count >= 12 && image.allSatisfy(\.isHexDigit) && id.hasPrefix(image))
        guard byID else { return image.isEmpty ? nil : image }
        guard let reference, !reference.isEmpty, !reference.hasPrefix("sha256:"), !id.hasPrefix(reference) else { return nil }
        return reference
    }
}

/// An image that runs translated here: built for another architecture than
/// the engine's — amd64 on Apple silicon. Its words, as the row's badge,
/// a detail's box, the verbs and the agents say them. Pure.
struct DockerEmulation: Equatable, Sendable {
    var image: DockerPlatform
    var engine: DockerPlatform

    /// Nil when either isn't known, when the image runs natively, or when
    /// the os differs: a Windows image on a Linux engine isn't emulated,
    /// it doesn't run at all.
    init?(image: DockerPlatform?, engine: DockerPlatform?) {
        guard let image, let engine, image.os == engine.os, !image.runsNatively(on: engine) else { return nil }
        self.image = image
        self.engine = engine
    }

    /// `Emulated: linux/amd64 on a linux/arm64 engine`.
    var title: String { "Emulated: \(image.description) on a \(engine.description) engine" }

    var summary: String {
        "The engine translates every instruction (Rosetta or QEMU): slower, often several times over, and some programs crash under it."
    }

    /// What runs it natively, for how it was made: a service Compose
    /// builds, another service, a container on its own. `built`: whether
    /// its project's files build the service (`ComposeFacts.built`), nil
    /// while they aren't read.
    func advice(for container: ContainerSummary, built: Bool?) -> String {
        let native = engine.short
        let pick = "A “platform: \(image.description)” in the compose file, or DOCKER_DEFAULT_PLATFORM in your shell, picks \(image.short) again."
        var text: String
        if Self.isService(container), built == true {
            text = "Compose built it for \(image.short). Built again for \(native) it runs natively — unless the compose file says “platform: \(image.description)”."
        } else if Self.isService(container), built == false {
            text = "If its image has a variant for \(native), pulling that and recreating the service runs it natively. " + pick
        } else if Self.isService(container) {
            text = "Recreated for \(native) it runs natively: built again, if its compose file builds it, else from its image's \(native) variant, if it has one. " + pick
        } else {
            text =
                "If its image has a variant for \(native), pull that and make the container again (Run Another Like It…). "
                + "An image with none can be built for it: docker build --platform \(engine.description)."
        }
        if !container.state.isUp, (container.exitCode ?? 0) != 0 {
            text += " Where nothing emulates \(image.short) it can't start at all: “exec format error”."
        }
        return text
    }

    /// The image's own box.
    var imageAdvice: String {
        "Built for \(image.description): this engine runs it emulated, slower. If it has a variant for \(engine.description), pulling that one runs natively."
    }

    /// The container's verb, which the box's button is too.
    func verbTitle(for container: ContainerSummary, built: Bool?) -> String {
        guard Self.isService(container) else { return "Pull the \(engine.short) Variant in a Tab" }
        return built == true ? "Rebuild as \(engine.short) in a Tab" : "Recreate as \(engine.short) in a Tab"
    }

    /// A compose project's service: a one-off (`compose run`) isn't one.
    static func isService(_ container: ContainerSummary) -> Bool {
        container.composeProject != nil && container.composeService != nil && !container.isOneOff
    }

    /// The image's verb: a pull through the engine.
    var imageVerbTitle: String { "Pull the \(engine.short) Variant" }

    /// What a badge's help says.
    var help: String { "\(title) — slower. Its detail says what to do." }
}
