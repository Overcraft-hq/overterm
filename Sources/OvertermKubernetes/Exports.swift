// The modules below this one, seen by every file of it and by whatever
// imports it: Package.swift's stack.
@_exported import OvertermDocker
@_exported import OvertermAPI

/// The app's settings, not SwiftUI's scene of that name: imported from
/// two modules here, the name needs saying once.
package typealias Settings = Overterm.Settings

/// A tab of the window, not SwiftUI's `Tab`: imported from two modules here.
package typealias Tab = Overterm.Tab
