import AppKit
import SwiftUI

private struct ToastView: View {
    let systemImage: String
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .foregroundStyle(.primary)
    }
}

/// A brief, click-through HUD (like the system volume/caps-lock indicators)
/// that confirms a capture succeeded or failed without stealing focus.
@MainActor
final class ToastPresenter {
    static let shared = ToastPresenter()

    private var window: NSWindow?
    private var dismissWorkItem: DispatchWorkItem?

    func show(systemImage: String, message: String, duration: TimeInterval = 1.4) {
        dismissWorkItem?.cancel()

        let hosting = NSHostingView(rootView: ToastView(systemImage: systemImage, message: message))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let window = self.window ?? {
            let newWindow = NSWindow(
                contentRect: .zero,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            newWindow.isOpaque = false
            newWindow.backgroundColor = .clear
            newWindow.hasShadow = true
            newWindow.level = .statusBar
            newWindow.ignoresMouseEvents = true
            newWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            self.window = newWindow
            return newWindow
        }()

        window.contentView = hosting
        window.setContentSize(size)

        // Center horizontally on whichever screen the pointer is on (matters
        // when the capture happened on a secondary display), low enough to
        // stay clear of the built-in screenshot thumbnail.
        let screenFrame = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        window.setFrameOrigin(CGPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.minY + screenFrame.height * 0.18
        ))

        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak window] in
            guard let window else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                window.animator().alphaValue = 0
            } completionHandler: {
                window.orderOut(nil)
            }
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }
}
