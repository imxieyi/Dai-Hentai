import DaiHentaiUI
import SwiftUI

@main
struct DaiHentaiApp: App {
    /// Live by default; `-DemoMode` runs offline with generated content (screenshots, UI tests).
    @State private var model = AppModel(configuration: .fromProcess())

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
