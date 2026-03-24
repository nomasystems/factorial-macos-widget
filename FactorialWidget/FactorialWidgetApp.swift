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
            Image(nsImage: buildMenuBarImage(timerText: service.menuBarTimer,
                                             shiftState: service.shiftState))
        }
        .menuBarExtraStyle(.window)

    }
}

// MARK: - Composite menu bar image

/// Renders [dot] [timer] [icon] into a single template-ready NSImage
/// so we have full control over layout in the MenuBarExtra label.
private func buildMenuBarImage(timerText: String, shiftState: FactorialService.ShiftState) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    let iconSize: CGFloat = 18
    let dotRadius: CGFloat = 3
    let spacing: CGFloat = 4

    let showTimer = !timerText.isEmpty

    // Measure timer text
    let timerAttrs: [NSAttributedString.Key: Any] = [.font: font]
    let timerSize = showTimer ? (timerText as NSString).size(withAttributes: timerAttrs) : .zero

    // Total width: dot + spacing + timer + spacing + icon
    var totalWidth: CGFloat = iconSize
    if showTimer {
        totalWidth = dotRadius * 2 + spacing + timerSize.width + spacing + iconSize
    } else {
        totalWidth = dotRadius * 2 + spacing + iconSize
    }
    let totalHeight: CGFloat = iconSize

    let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { rect in
        // Detect menu bar appearance at render time to pick the right foreground color
        let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fg: NSColor = isDark ? .white : .black

        var x: CGFloat = 0
        let midY = rect.midY

        // Draw dot (always colored)
        let dotColor: NSColor = switch shiftState {
        case .active: .systemGreen
        case .paused: .systemOrange
        case .idle:   .systemRed
        }
        dotColor.setFill()
        let dotRect = NSRect(x: x, y: midY - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
        NSBezierPath(ovalIn: dotRect).fill()
        x += dotRadius * 2 + spacing

        // Draw timer text (adapts to menu bar appearance)
        if showTimer {
            let coloredAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
            let textY = midY - timerSize.height / 2
            (timerText as NSString).draw(at: NSPoint(x: x, y: textY), withAttributes: coloredAttrs)
            x += timerSize.width + spacing
        }

        // Draw icon tinted to match menu bar appearance
        let iconRect = NSRect(x: x, y: midY - iconSize / 2, width: iconSize, height: iconSize)
        menuBarIcon.draw(in: iconRect)
        fg.setFill()
        iconRect.fill(using: .sourceAtop)

        return true
    }

    // Non-template so macOS doesn't override our colors (dot must stay colored)
    image.isTemplate = false
    return image
}
