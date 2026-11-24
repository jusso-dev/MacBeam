import SwiftUI

@main
struct MacBeamApp: App {
    @State private var library = ConnectionLibraryStore()
    @State private var discovery = BonjourMacDiscovery()

    var body: some Scene {
        WindowGroup {
            HomeView(library: library, discovery: discovery)
        }
    }
}
