import SwiftUI

@main
struct EtherReaderApp: App {
    var body: some Scene {
        WindowGroup("Ether Reader") {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
    }
}
