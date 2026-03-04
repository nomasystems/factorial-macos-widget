import SwiftUI

private let menuBarIcon: NSImage = {
    let img = (NSImage(named: "FactorialIcon") ?? NSImage()).copy() as! NSImage
    img.size = NSSize(width: 18, height: 18)
    img.isTemplate = true
    return img
}()

@main
struct FactorialWidgetApp: App {
    @StateObject private var service = FactorialService()

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
