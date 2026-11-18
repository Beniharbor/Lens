import SwiftUI
import KeyboardShortcuts

@main
struct LensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = OCRController.shared
    @StateObject private var grid = DownloadsStackController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller, grid: grid)
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
        DownloadsStackController.shared.start()
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
    @ObservedObject var grid: DownloadsStackController

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
        Menu("Dock Grid Folder") {
            folderToggle("Downloads", .downloadsDirectory)
            folderToggle("Desktop", .desktopDirectory)
            folderToggle("Documents", .documentDirectory)
            if !isStandardFolder(grid.rootFolder) {
                Toggle(grid.rootFolderName, isOn: .constant(true))
            }
            Divider()
            Button("Choose Folder…") {
                grid.chooseRootFolder()
            }
        }
        Button("Reset Dock Grid Size") {
            grid.resetSize()
        }
        Divider()
        Button("Quit Lens") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func folderURL(_ directory: FileManager.SearchPathDirectory) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask)[0]
    }

    private func isStandardFolder(_ url: URL) -> Bool {
        [.downloadsDirectory, .desktopDirectory, .documentDirectory].contains { grid.isRootFolder(folderURL($0)) }
    }

    /// A checkmarked menu item; choosing it points the Dock grid at that folder.
    private func folderToggle(_ title: String, _ directory: FileManager.SearchPathDirectory) -> some View {
        let url = folderURL(directory)
        return Toggle(title, isOn: Binding(
            get: { grid.isRootFolder(url) },
            set: { if $0 { grid.setRootFolder(url) } }
        ))
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
