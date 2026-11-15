import SwiftUI

/// A Secret's part of its detail's Overview: before Show, what its row
/// says and the Show button (on production, the question first); after,
/// its keys with every value masked — its length shown — one revealed at
/// a time, Copy for one, Hide for all, and a TLS Secret's certificate.
/// The revealed value isn't selectable: Copy is the one way out of it.
struct KubeSecretView: View {
    @ObservedObject var page: KubernetesPageModel
    @ObservedObject var secret: KubeSecretSession
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: secret.state == .shown ? "lock.open.fill" : "lock.fill").foregroundStyle(theme.text3)
                Text(verbatim: headline).font(.system(size: ChromeMetrics.text(12.5), weight: .semibold)).foregroundStyle(theme.text)
                Spacer(minLength: 0)
                if secret.state == .shown {
                    Button("Hide") { secret.drop(.asked) }.font(.system(size: ChromeMetrics.text(11.5))).accessibilityIdentifier("kubernetes.secret.hide")
                }
            }
            switch secret.state {
            case .hidden: hidden
            case .confirming: confirming
            case .loading: ProgressView().controlSize(.small)
            case .failed(let reason):
                Text(verbatim: reason).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(TabStatusStyle.failed).fixedSize(horizontal: false, vertical: true)
                showButton("Try Again")
            case .shown: shown
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.text.opacity(0.04)))
        .accessibilityIdentifier("kubernetes.secret")
    }

    private var headline: String {
        let type = secret.type ?? secret.listedType ?? "Secret"
        let keys = secret.state == .shown ? secret.entries.count : secret.listedKeys
        return type + (keys.map { " · \($0) key\($0 == 1 ? "" : "s")" } ?? "")
    }

    private func showButton(_ title: String = "Show Values") -> some View {
        Button(title) { _ = page.showSecret() }
            .font(.system(size: ChromeMetrics.text(12)))
            .accessibilityIdentifier("kubernetes.secret.show")
    }

    // MARK: Before Show

    private var hidden: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let note = secret.droppedNote {
                Text(verbatim: note).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(TabStatusStyle.waiting).accessibilityIdentifier("kubernetes.secret.dropped")
            }
            Text(
                verbatim:
                    "Not read: its keys come only with its values, all at once. Show reads them, masked until you reveal one, and drops them when you leave this Secret, hide the page, change context, or after \(KubeSecretSession.said(secret.timeout)) without a look."
            )
            .font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2).fixedSize(horizontal: false, vertical: true)
            showButton()
        }
    }

    private var confirming: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "\(secret.ref.context) is a production context. Show reads every value of this Secret at once.")
                .font(.system(size: ChromeMetrics.text(12), weight: .medium)).foregroundStyle(TabStatusStyle.failed).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "Asked once for \(secret.ref.context) until Overterm quits.").font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3)
            HStack(spacing: 8) {
                Button("Show Values") { secret.confirm() }.accessibilityIdentifier("kubernetes.secret.confirm")
                Button("Cancel") { secret.cancelConfirmation() }.accessibilityIdentifier("kubernetes.secret.cancel")
            }
            .font(.system(size: ChromeMetrics.text(12)))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(TabStatusStyle.failed.opacity(0.6)))
    }

    // MARK: Shown

    private var shown: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Values masked · one revealed at a time · hidden again after \(KubeSecretSession.said(secret.timeout)) without a look")
                .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3)
            ForEach(secret.entries) { entry in row(entry) }
            if let leaf = secret.certificates.first { certificate(leaf, chain: secret.certificates.count) }
        }
    }

    private func row(_ entry: KubeSecretEntry) -> some View {
        let isRevealed = secret.revealed == entry.key
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: entry.key).font(.system(size: ChromeMetrics.text(12), design: .monospaced)).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                    .frame(width: 140, alignment: .leading)
                if !isRevealed {
                    Text(verbatim: entry.masked).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3)
                        .accessibilityIdentifier("kubernetes.secret.masked.\(entry.key)")
                }
                Spacer(minLength: 0)
                if !entry.isPrivateKey {
                    Button {
                        if isRevealed { secret.conceal() } else { secret.reveal(entry.key) }
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye").font(.system(size: ChromeMetrics.text(11)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.text2)
                    .help(isRevealed ? "Mask it again" : "Reveal this value (only this one)")
                    .accessibilityIdentifier("kubernetes.secret.reveal.\(entry.key)")
                    Button {
                        page.copySecretValue(entry.key)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: ChromeMetrics.text(11)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.text2)
                    .help("Copy this value")
                    .accessibilityIdentifier("kubernetes.secret.copy.\(entry.key)")
                }
            }
            if isRevealed, let text = secret.revealedText {
                ScrollView {
                    Text(verbatim: text).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced)).foregroundStyle(theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 160)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 4).fill(theme.text.opacity(0.05)))
                .accessibilityIdentifier("kubernetes.secret.value")
                if entry.isBinary { Text("Binary: shown as base64").font(.system(size: ChromeMetrics.text(10.5))).foregroundStyle(theme.text3) }
            }
        }
    }

    // MARK: A TLS Secret's certificate

    private func certificate(_ certificate: KubeCertificate, chain: Int) -> some View {
        let validity = certificate.validity()
        let (said, color): (String, Color) =
            switch validity {
            case .valid: ("valid", TabStatusStyle.done)
            case .expiringSoon(let days): ("expires in \(days) day\(days == 1 ? "" : "s")", TabStatusStyle.waiting)
            case .expired: ("expired", TabStatusStyle.failed)
            case .notYetValid: ("not valid yet", TabStatusStyle.waiting)
            }
        return VStack(alignment: .leading, spacing: 5) {
            Text("Certificate (tls.crt)").font(.system(size: ChromeMetrics.text(10.5), weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3).padding(.top, 6)
            fact("Subject", certificate.subject)
            fact("Issuer", certificate.isSelfSigned ? "self-signed" : certificate.issuer)
            if !certificate.alternativeNames.isEmpty { fact("Names", certificate.alternativeNames.joined(separator: ", ")) }
            fact("Valid from", certificate.notBefore.formatted(date: .abbreviated, time: .shortened))
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                label("Valid until")
                Text(verbatim: certificate.notAfter.formatted(date: .abbreviated, time: .shortened)).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text)
                Text(verbatim: said).font(.system(size: ChromeMetrics.text(11.5), weight: .medium)).foregroundStyle(color)
                    .accessibilityIdentifier("kubernetes.secret.certificate.validity")
            }
            if certificate.isCA { fact("CA", "yes") }
            if chain > 1 { fact("Chain", "\(chain - 1) more certificate\(chain == 2 ? "" : "s") after it") }
        }
        .accessibilityIdentifier("kubernetes.secret.certificate")
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3).frame(width: 128, alignment: .leading)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            label(title)
            Text(verbatim: value).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
