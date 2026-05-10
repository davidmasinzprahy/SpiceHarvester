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
            // Build an attributed string that color-codes log lines by
            // severity (ERROR red, WARNING orange, INFO secondary, default
            // primary). The base log format is `[ts] [LEVEL] file phase: msg`,
            // so a regex on the bracketed `LEVEL` token is sufficient.
            // Cost is O(n) per refresh; the log is rewritten on phase
            // boundaries, not per-line, so this isn't on the hot path.
            let attributed = Self.attributedLog(text, fontSize: fontSize)
            textView.textStorage?.setAttributedString(attributed)
            if autoScrollToBottom && context.coordinator.userPinnedToBottom {
                textView.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0))
            }
        }
        // Rebuild font in case Dynamic Type / system size changes between updates.
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// Builds an `NSAttributedString` from a raw log dump. Each line is
    /// scanned for a severity token (`[ERROR]`, `[WARNING]`, `[INFO]`)
    /// and the *whole* line is colored accordingly so the user can skim
    /// for problems without reading every character. Lines without a
    /// recognized token use `labelColor` (default primary).
    private static func attributedLog(_ text: String, fontSize: CGFloat) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
        let nsText = text as NSString
        var lineStart = 0
        while lineStart < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: lineStart, length: 0))
            let line = nsText.substring(with: lineRange) as String
            if let color = severityColor(for: line) {
                result.addAttribute(.foregroundColor, value: color, range: lineRange)
            }
            lineStart = NSMaxRange(lineRange)
        }
        return result
    }

    /// Maps a log line to its accent color. Tokens are matched
    /// case-insensitively and bracketed (`[ERROR]`) so fragments inside
    /// extracted JSON like `"warning"` don't accidentally re-color
    /// payload lines.
    private static func severityColor(for line: String) -> NSColor? {
        let upper = line.uppercased()
        if upper.contains("[ERROR]") || upper.contains("[FATAL]") {
            return .systemRed
        }
        if upper.contains("[WARNING]") || upper.contains("[WARN]") {
            return .systemOrange
        }
        if upper.contains("[INFO]") || upper.contains("[DEBUG]") {
            return .secondaryLabelColor
        }
        return nil
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
