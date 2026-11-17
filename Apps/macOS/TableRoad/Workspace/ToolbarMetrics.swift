import AppKit
import SwiftUI

/// Works out how wide the connection pill can be from where the toolbar actually put things, instead of a
/// hand-tuned margin. Toolbar items can't stretch, and an item that's too wide sends the pill and everything after
/// it into the overflow (») menu, where it can't be measured and the toolbar doesn't bring it back even once it
/// shrinks. So the width must never be too big, even for a moment.
///
/// The target width is SwiftUI's detail-column width minus two measured amounts that don't depend on the window's
/// size: how far into the detail column the pill starts, and how much room the right-hand buttons take. Probes
/// behind the pill and each right-hand button report their window-space frames to measure those.
///
/// The detail width and the toolbar's own layout don't update in a fixed order, so a jump in window size (zoom,
/// tiling) can briefly disagree: shrinking is applied at once, but growing waits until the toolbar has caught
/// up. If the pill still ends up in the overflow menu, it drops to its minimum so the toolbar brings it back.
@MainActor @Observable
final class ToolbarMetrics {
    /// The detail column's width (it runs to the window's trailing edge, inspector included).
    var detailWidth: CGFloat = 800 {
        didSet { apply() }
    }
    /// Number of right-hand buttons currently shown, used before they've been measured.
    var trailingCount = 3 {
        didSet { apply() }
    }

    /// The width the pill is actually given (see the type's notes on growing and overflow).
    private(set) var pillWidth: CGFloat = minimum
    private var isInOverflow = false
    private var pendingGrowth: Task<Void, Never>?

    /// Distance from the detail column's leading edge to the pill's. Kept while the pill is unmeasurable.
    private var pillOffset: CGFloat? {
        didSet { apply() }
    }
    /// Frames of the right-hand buttons, keyed by button; only their combined span is used.
    private var trailingFrames: [String: CGRect] = [:] {
        didSet { apply() }
    }

    /// Toolbar bits the probes can't see: the gap before the right-hand capsule, the capsule's padding around
    /// the outer buttons, and the window's trailing inset. Tuned on macOS 26 (12 fits exactly), plus 6pt of slack.
    private static let trailingChrome: CGFloat = 18
    /// Before measuring: where the pill starts (after the database + New Query capsule) and each button's size.
    private static let estimatedOffset: CGFloat = 110
    private static let estimatedButton: CGFloat = 42
    private static let minimum: CGFloat = 200

    private var targetWidth: CGFloat {
        let width = detailWidth - (pillOffset ?? Self.estimatedOffset) - trailingReserve
        return max(Self.minimum, width.rounded(.down))
    }

    private var trailingReserve: CGFloat {
        let frames = trailingFrames.values
        guard frames.count == trailingCount, let minX = frames.map(\.minX).min(),
            let maxX = frames.map(\.maxX).max()
        else {
            return CGFloat(trailingCount) * Self.estimatedButton + Self.trailingChrome
        }
        return maxX - minX + Self.trailingChrome
    }

    private func apply() {
        let target = isInOverflow ? Self.minimum : targetWidth
        if target <= pillWidth {
            pendingGrowth?.cancel()
            pendingGrowth = nil
            if pillWidth - target >= 0.5 { pillWidth = target }
        } else if pendingGrowth == nil {
            pendingGrowth = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled else { return }
                pendingGrowth = nil
                let target = isInOverflow ? Self.minimum : targetWidth
                if abs(pillWidth - target) >= 0.5 { pillWidth = target }
            }
        }
    }

    fileprivate func report(pill frame: CGRect?, windowWidth: CGFloat?) {
        guard let frame, let windowWidth else {
            // Gone from the toolbar: either the window closed or the toolbar moved it into the overflow menu.
            if !isInOverflow {
                isInOverflow = true
                apply()
            }
            return  // keep the last measurement
        }
        if isInOverflow {
            isInOverflow = false
            apply()
        }
        let offset = frame.minX - (windowWidth - detailWidth)
        // Half-point tolerance: the pill's own resize re-lays out the toolbar and reports again.
        if pillOffset.map({ abs($0 - offset) >= 0.5 }) ?? true { pillOffset = offset }
    }

    fileprivate func report(trailing key: String, frame: CGRect?) {
        guard let frame else { return }  // in the overflow menu: keep the last measurement
        // Only the span matters, so a move that keeps the size (the group follows the pill) shifts every frame
        // together, keeping the span consistent until the other buttons report.
        if let old = trailingFrames[key], abs(old.width - frame.width) < 0.5, trailingFrames.count == trailingCount {
            let shift = frame.minX - old.minX
            if abs(shift) >= 0.5 { trailingFrames = trailingFrames.mapValues { $0.offsetBy(dx: shift, dy: 0) } }
            return
        }
        trailingFrames[key] = frame
    }

    func forgetTrailing(_ key: String) {
        trailingFrames[key] = nil
    }
}

extension View {
    /// Reports this view's frame (in window coordinates) as the pill's, plus the window width.
    func measuringToolbarPill(_ metrics: ToolbarMetrics) -> some View {
        background(
            ToolbarProbe { frame, window in
                metrics.report(pill: frame, windowWidth: window?.frame.width)
            })
    }

    /// Reports this view's frame as one of the right-hand toolbar buttons.
    func measuringToolbarButton(_ key: String, in metrics: ToolbarMetrics) -> some View {
        background(
            ToolbarProbe { frame, _ in
                metrics.report(trailing: key, frame: frame)
            }
        )
        .onDisappear { metrics.forgetTrailing(key) }
    }
}

/// A transparent view that reports its window-space frame whenever the window or the toolbar re-lays out.
private struct ToolbarProbe: NSViewRepresentable {
    let onChange: @MainActor (CGRect?, NSWindow?) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
        view.scheduleReport()
    }

    final class ProbeView: NSView {
        var onChange: (@MainActor (CGRect?, NSWindow?) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var pending = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Observers are dropped whenever the view leaves its window (which happens before it's freed).
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window {
                // Toolbar items move without their own size changing (sidebar toggles, window resizes), and a
                // view isn't told when an ancestor moves, so listen to the window as well.
                for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
                    observers.append(
                        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                            [weak self] _ in
                            MainActor.assumeIsolated { self?.scheduleReport() }
                        })
                }
            }
            scheduleReport()
        }

        override func layout() {
            super.layout()
            scheduleReport()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            scheduleReport()
        }

        /// Reads the frame after the current layout pass, and again once animations (sidebar collapse) settle.
        func scheduleReport() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                pending = false
                report()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.report() }
            }
        }

        private func report() {
            guard let window, !isHiddenOrHasHiddenAncestor else {
                onChange?(nil, nil)
                return
            }
            onChange?(convert(bounds, to: nil), window)
        }
    }
}
