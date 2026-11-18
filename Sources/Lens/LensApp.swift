import SwiftUI
import KeyboardShortcuts

@main
struct LensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = OCRController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            MenuBarLabel(controller: controller)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Regular app so Lens has a Dock icon: clicking it opens the Downloads
        // grid (DownloadsStackController). The OCR menu-bar item is unchanged.
        NSApp.setActivationPolicy(.regular)
        DownloadsStackController.shared.applyDockIcon()
        OCRController.shared.registerHotkey()
    }

    /// Sent every time the Dock icon is clicked while Lens is running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DownloadsStackController.shared.toggle()
        return false
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var controller: OCRController

    var body: some View {
        switch controller.state {
        case .idle:
            Image(nsImage: MenuBarIcon.mark)
        case .capturing:
            Image(systemName: "viewfinder")
        case .recognizing:
            Image(systemName: "ellipsis.circle")
        case .done:
            Image(systemName: "checkmark.circle.fill")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var controller: OCRController

    var body: some View {
        Text(statusLine)
        if let snippet = controller.lastCopiedSnippet {
            Text("“\(snippet)”")
        }
        Divider()
        Button("Capture Text") {
            controller.captureAndRecognize()
        }
        .keyboardShortcut("c")
        KeyboardShortcuts.Recorder("Shortcut:", name: .captureText)
        Divider()
        Button("Reset Downloads Grid Size") {
            DownloadsStackController.shared.resetSize()
        }
        Divider()
        Button("Quit Lens") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch controller.state {
        case .idle: return "Select a region to copy its text"
        case .capturing: return "Selecting region…"
        case .recognizing: return "Reading text…"
        case .done: return "Copied to clipboard"
        case .failed(let message): return message
        }
    }
}
