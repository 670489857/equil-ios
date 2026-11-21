import SwiftUI

@main
struct EquilProbeApp: App {
    @StateObject private var ble = BLEManager()

    var body: some Scene {
        WindowGroup {
            ContentView(ble: ble)
        }
    }
}
