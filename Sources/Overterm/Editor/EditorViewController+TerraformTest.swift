import AppKit

/// `terraform test`'s failures in the editor (analysis 2.9, stage 2d): a
/// root's last test run marks the lines it failed at — an assertion's
/// condition, a file that doesn't parse — in the test files it names,
/// beside validate's marks, over the text as saved (an edited buffer
/// keeps none; its edit dropped them, as validate's).
extension EditorViewController {
    static let terraformTestSource = "terraform test"

    func observeTerraformTestDiagnostics() {
        NotificationCenter.default.addObserver(forName: .terraformTestDiagnostics, object: nil, queue: .main) { [weak self] note in
            let files = Set(note.userInfo?["files"] as? [String] ?? [])
            MainActor.assumeIsolated {
                guard let self else { return }
                for buffer in self.buffers {
                    guard let url = buffer.url, files.contains(url.standardizedFileURL.path) else { continue }
                    self.applyTerraformTestDiagnostics(buffer)
                }
            }
        }
    }

    /// Lays the last test run's failures of `buffer`'s file over it, in
    /// place of the ones before; never over edits not yet saved.
    func applyTerraformTestDiagnostics(_ buffer: EditorBuffer) {
        guard let url = buffer.url, TerraformTestFiles.isTestFileName(url.lastPathComponent) else { return }
        var kept = buffer.terraformDiagnostics.filter { $0.source != Self.terraformTestSource }
        if !buffer.document.isDirty {
            let text = buffer.storage.string as NSString
            kept += TerraformTestResults.shared.diagnostics(for: url).compactMap { diagnostic in
                guard let start = diagnostic.start else { return nil }
                return EditorDiagnostic(
                    range: TerraformValidation.range(from: start, to: diagnostic.end, in: text), severity: diagnostic.severity == .error ? .error : .warning,
                    message: diagnostic.message, source: Self.terraformTestSource)
            }
        }
        guard kept != buffer.terraformDiagnostics else { return }
        buffer.terraformDiagnostics = kept
        if buffer === active {
            textView.diagnostics = buffer.diagnostics
            updateProblemLines()
            updateStatus()
        }
    }
}
