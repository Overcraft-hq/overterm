import AppKit
import SwiftUI

extension EditorBuffer {
    /// A Bruno request (`.bru`): its form, kept beside the text.
    package var request: APIRequestModel? {
        get { requestPart as? APIRequestModel }
        set { requestPart = newValue }
    }
}

extension EditorViewController {
    /// The window's API client: where a new request's draft lives, and the
    /// collection a saved one goes into.
    package var apiWorkspace: APIWorkspace? {
        get { apiWorkspaceStorage as? APIWorkspace }
        set { apiWorkspaceStorage = newValue }
    }
}

extension APIRequestModel: EditorRequestPart {}

/// The API client's part in the shell under it, set once (`OvertermFeatures`).
package enum APIFeature {
    package static func install() {
        EditorViewController.hooksStorage.attach.append { editor, buffer in editor.attachRequest(buffer) }
        EditorViewController.hooksStorage.requestView.append { editor, buffer in
            buffer.request.map { AnyView(APIRequestView(model: $0, theme: editor.chrome)) }
        }
        EditorViewController.hooksStorage.draft.append { editor, buffer, done in
            guard editor.isDraft(buffer) else { return false }
            editor.saveDraft(buffer, then: done)
            return true
        }
        // A new request closed unsaved is gone, as Postman's tab is.
        EditorViewController.hooksStorage.closed.append { editor, buffer in
            if let url = buffer.url { editor.apiWorkspace?.discardDraft(url) }
        }
        BrowserMCP.featuresStorage.append(
            BrowserMCP.Provider(
                handles: { $0.hasPrefix("api_") }, enabled: { $0.apiAgentControl },
                unavailable: "The API client isn't available to agents — Settings ▸ API Client.",
                tools: { APIMCP.tools },
                instructions: { _ in
                    "The API client of your checkout's Bruno collection: api_collections lists its requests, api_send runs one with its tests, api_request sends a one-off, api_run runs the collection — use it to check an endpoint you changed."
                },
                call: { name, arguments, context in
                    guard let api = context.api as? AgentAPI else {
                        return BrowserMCP.errorResult("The API client isn't available to agents — Settings ▸ API Client.")
                    }
                    return try await APIMCP.call(name, arguments, api: api)
                }))
    }
}
