import SwiftUI
import AppKit

/// `NSTextView`-backed log display. Replaces SwiftUI's `Text` inside a
/// `ScrollView` for the Log card because:
///
///  1. `Text(longString)` rebuilds the entire layout tree on every update —
///     for a 100 kB log that's tens of milliseconds per refresh and visible
///     UI lag during long runs.
///  2. `NSTextView` natively supports incremental text updates, native
///     find/select gestures, and respects macOS keyboard shortcuts users
///     expect (Cmd+A select all, Cmd+C copy, two-finger swipe scroll).
///  3. Auto-scroll-to-bottom happens at the AppKit layer with `scrollRangeToVisible`
///     instead of `ScrollViewReader.scrollTo` + `.id()` hacks.
///
/// `text` is the substring-filtered view of the on-disk log (whatever the
/// owner SwiftUI view computed); we don't filter inside the view.
struct SHLogTextView: NSViewRepresentable {
    let text: String
    /// Monospaced font size matches the SwiftUI version (10.5 pt) so the
    /// visual rhythm of the rest of the app is unchanged.
    var fontSize: CGFloat = 10.5
    /// When true, text appended at the end keeps the view scrolled to bottom.
    /// Disabled when the user has scrolled up to read history; we re-enable
    /// once they scroll back to the bottom (handled in `Coordinator`).
    var autoScrollToBottom: Bool = true

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false

        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 6, height: 6)

        // Subscribe to scroll changes so we can disable auto-scroll when
        // the user reads earlier output.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        scroll.contentView.postsBoundsChangedNotifications = true

        context.coordinator.textView = textView
        context.coordinator.scrollView = scroll
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            // `setString` clobbers the whole text — for incremental updates
            // we'd need a smarter diff, but the log is rewritten by the
            // owner on phase boundaries, so this is fine in practice.
            textView.string = text
            if autoScrollToBottom && context.coordinator.userPinnedToBottom {
                textView.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0))
            }
        }
        // Rebuild font in case Dynamic Type / system size changes between updates.
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        /// User is considered "pinned to bottom" when the visible rect's
        /// bottom edge is within 24 pt of the document end. This makes
        /// auto-scroll resume the moment they scroll back down — the
        /// expected log-tail behavior.
        var userPinnedToBottom: Bool = true

        @objc func boundsDidChange(_ notification: Notification) {
            guard let scrollView,
                  let documentView = scrollView.documentView else { return }
            let visibleBottom = scrollView.contentView.bounds.maxY
            let documentBottom = documentView.bounds.maxY
            userPinnedToBottom = (documentBottom - visibleBottom) < 24
        }
    }
}
