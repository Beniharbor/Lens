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
        // Menu-bar agent app: no dock icon (also set via LSUIElement in Info.plist).
        NSApp.setActivationPolicy(.accessory)
        OCRController.shared.registerHotkey()
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
