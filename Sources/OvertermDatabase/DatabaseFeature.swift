import Foundation

/// The databases' part in the shell under them, set once (`OvertermFeatures`).
package enum DatabaseFeature {
    package static func install() {
        DatabaseEditor.install()
        BrowserMCP.featuresStorage.append(
            BrowserMCP.Provider(
                handles: { $0.hasPrefix("db_") || $0.hasPrefix("storage_") }, enabled: { $0.databaseAgentAccess },
                unavailable: "The databases aren't available to agents — Settings ▸ Database.",
                tools: { DatabaseMCP.tools },
                instructions: { _ in
                    "The user's databases and buckets (Overterm's Database panel): db_connections and db_schema show what is there, db_query runs one statement and returns rows — reads; storage_list and storage_read browse S3/GCS. Check real data instead of guessing a schema."
                },
                call: { name, arguments, _ in try await DatabaseMCP.call(name, arguments, model: DatabaseModel.shared) }))
    }
}
