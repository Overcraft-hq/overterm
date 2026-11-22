import OvertermE2E

// Everything is in the app's library modules (Package.swift), which the
// tests import too; this executable only starts them — with the end-to-end
// scenarios where the build has them (`#if E2E`).
#if E2E
MainActor.assumeIsolated { E2EStart.install() }
#endif
AppMain.run()
