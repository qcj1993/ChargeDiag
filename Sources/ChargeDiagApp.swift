import SwiftUI

@main
struct ChargeDiagApp: App {
    @UIApplicationDelegateAdaptor(ChargeDiagDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
