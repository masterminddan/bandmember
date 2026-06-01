import AppKit

/// A transparent overlay view that hides the mouse cursor while the pointer is
/// inside its bounds, and restores it on exit. Layered on top of fullscreen
/// video / karaoke presentation windows so the pointer disappears over the
/// performance display but stays visible everywhere else (e.g. the operator's
/// control display).
///
/// `NSCursor.hide()`/`unhide()` are app-global and reference counted, so this
/// view carefully balances exactly one hide with one unhide via `isHidden`.
/// It uses an `.activeAlways` tracking area so it works even when the app is
/// not frontmost — the common case where the operator is interacting with the
/// main window on another screen.
final class CursorHidingView: NSView {
    private var didHide = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Hide immediately if the pointer is already over us when the window
        // opens (tracking areas only fire on the *next* movement otherwise).
        guard let window else { return }
        let pointInWindow = window.mouseLocationOutsideOfEventStream
        let pointInView = convert(pointInWindow, from: nil)
        if bounds.contains(pointInView) { hideCursor() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Window is going away (or being reparented) — make sure we don't leave
        // the cursor stuck hidden.
        if newWindow == nil { showCursor() }
    }

    override func mouseEntered(with event: NSEvent) { hideCursor() }
    override func mouseExited(with event: NSEvent) { showCursor() }

    /// Let clicks fall through to whatever is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func hideCursor() {
        guard !didHide else { return }
        NSCursor.hide()
        didHide = true
    }

    private func showCursor() {
        guard didHide else { return }
        NSCursor.unhide()
        didHide = false
    }

    deinit { showCursor() }
}
