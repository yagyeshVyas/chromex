import SwiftUI

@main
struct CHROMEXApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(ChromexColor.electricBlue)
                .preferredColorScheme(preferredScheme)
        }
    }

    private var preferredScheme: ColorScheme? {
        switch model.preferences.theme {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}
