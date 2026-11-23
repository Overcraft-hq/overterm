#if E2E
/// How the app starts a scenario (`AppDelegate.e2eStart`): set by
/// `main.swift` before the app runs, so the shell never names this module.
package enum E2EStart {
    @MainActor package static func install() {
        AppDelegate.e2eStart = { scenario, controller in E2ERunner.start(scenario, app: controller) }
    }
}
#endif
