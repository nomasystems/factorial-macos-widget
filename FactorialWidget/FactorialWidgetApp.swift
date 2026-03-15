import SwiftUI
import ServiceManagement

private let menuBarIcon: NSImage = {
    let img = (NSImage(named: "FactorialIcon") ?? NSImage()).copy() as! NSImage
    img.size = NSSize(width: 18, height: 18)
    img.isTemplate = true
    return img
}()

@main
struct FactorialWidgetApp: App {
    @StateObject private var service = FactorialService()

    init() {
        try? SMAppService.mainApp.register()
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(service)
        } label: {
            Image(nsImage: menuBarIcon)
        }
        .menuBarExtraStyle(.window)

    }
}
