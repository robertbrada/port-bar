//
//  MenuText.swift
//  PortBar
//

import AppKit

/// Text measurement for the menus, kept apart from `PortMenu` so it has no
/// dependencies and can be exercised on its own.
enum MenuText {

    /// Every submenu is given this width, so its edge — and *which side of the
    /// parent it opens on* — doesn't change as you move down the list. Near the
    /// right edge of the screen a wide submenu doesn't fit on the right and
    /// AppKit flips it to the left of the menu, while a narrow one stays put;
    /// that flip is what made the position look random.
    ///
    /// Derived from the widest label we can actually emit rather than
    /// hardcoded, so it survives a wording change or a different system font.
    /// Computed once and cached. Not a `static let`: that initialiser runs
    /// `nonisolated`, and measuring text touches `NSFont` on the main actor.
    static var submenuTextWidth: CGFloat {
        if let cachedTextWidth { return cachedTextWidth }
        // Three things set the width. The action titles, because an action that
        // wrapped would be absurd — keep this list in step with what `PortMenu`
        // actually emits. The widest *fact*, measured from the value column it
        // starts at, because a wrapped `com.docker.backend` reads as damage
        // where a wrapped project name reads as a long name. And a comfort
        // floor for the name heading.
        let actions = ["Open in Terminal", "Reveal in Finder", "Open in Browser",
                       "Copy Address", "Force Stop", "View Logs", "Copy URL"]
        let facts = ["com.docker.backend", "999999", "0.0.0.0"]
        let widestFact = detailValueColumn + (facts.map { width(of: $0) }.max() ?? 0)
        // The floor exists for the *heading*: the full project name, which is
        // shown only when the row abbreviated it, and which gets the whole
        // width because it has no label beside it. 190 fits
        // `design-system-react-demo` (167pt) and `northwind-mobile-app` (136pt)
        // on one line. A 23-character name measured 150.9pt against the old
        // 150pt budget — it missed by nine tenths of a point and wrapped to a
        // four-character orphan line, which is what made the footer look broken.
        let comfort: CGFloat = 190
        let measured = max(comfort, widestFact, actions.map { width(of: $0) }.max() ?? 160)
        cachedTextWidth = measured
        return measured
    }

    private static var cachedTextWidth: CGFloat?

    /// Labels on the submenu's footer facts. **Keep in step with
    /// `PortEntry.detailFacts`** — they set the value column, so a longer label
    /// added there and not here would overrun its own value.
    private static let detailLabels = ["Process", "PID", "Binding"]

    /// x where a footer fact's *value* starts, so the labels form a column and
    /// the values form another. Derived from the labels rather than picked, so
    /// a reworded label can't quietly break the alignment.
    static var detailValueColumn: CGFloat {
        if let cachedValueColumn { return cachedValueColumn }
        // A gap wide enough that label and value read as two columns rather
        // than as one phrase with a space in it.
        let gap: CGFloat = 12
        let column = (detailLabels.map { width(of: $0) }.max() ?? 0) + gap
        cachedValueColumn = column
        return column
    }

    private static var cachedValueColumn: CGFloat?

    /// A footer line as `label`, a tab stop, then `value`.
    ///
    /// **This is the one place an `attributedTitle` is allowed**, and the reason
    /// the general ban doesn't apply is that these items are *disabled*: AppKit
    /// never highlights them, so the colours can't fail to invert. The colour
    /// still has to be a dynamic system one, because an attributed title is
    /// drawn exactly as given — AppKit won't grey it for us.
    ///
    /// Pass an empty `label` for a value's continuation line: `headIndent`
    /// keeps it in the value column, so a wrapped name reads as one field
    /// rather than as another nameless fact.
    static func columned(_ label: String, _ value: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: detailValueColumn)]
        style.defaultTabInterval = detailValueColumn
        style.headIndent = detailValueColumn
        return NSAttributedString(string: label + "\t" + value, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.disabledControlTextColor,
            .paragraphStyle: style,
        ])
    }

    /// A footer line with no label — the name heading. Attributed like the
    /// facts rather than left as a plain disabled title, so the whole block is
    /// one shade of grey instead of two that nearly match.
    static func unlabelled(_ value: String) -> NSAttributedString {
        NSAttributedString(string: value, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.disabledControlTextColor,
        ])
    }

    /// AppKit's own margins around an item's title — the state (checkmark)
    /// column on the left, padding on the right. Erring high keeps the width
    /// constant; erring low lets content force the menu wider again, which is
    /// the bug being fixed.
    static let submenuChrome: CGFloat = 48

    static var submenuWidth: CGFloat { submenuTextWidth + submenuChrome }

    /// How much room a row's *label* gets, after its `1234 · ` prefix.
    ///
    /// Tuned to fill the menu rather than to set its width. AppKit reserves a
    /// shared right-hand column across every item for key equivalents — `⌘Q` on
    /// *Quit PortBar* — and the submenu arrows sit in it, which left a visible
    /// gap between a row's text and its arrow. This budget spends that slack:
    /// the widest row is ~172pt against a menu already at least as wide as
    /// 144pt (*Show System Ports (18)*) plus that column. Going much past this
    /// starts widening the menu instead of filling it — 145pt would fit
    /// `northwind-mobile-app` (136pt) whole but takes the row back to 185pt,
    /// which was too wide.
    ///
    /// The value is tuned by *rendered characters*, not by eye: 134pt is where
    /// both of the author's long rows gain exactly one character over 128pt
    /// while the row grows only 4pt.
    static let rowLabelWidth: CGFloat = 134

    /// Middle-truncated, **not** tail-truncated. Names that need shortening
    /// come from monorepos and compose files, which share long prefixes and
    /// differ at the end — `northwind-customer-dashboard-db` versus
    /// `…-redis`. Cutting the tail renders both as `northwind-customer-dashbo…`,
    /// throwing away the only part that identifies them.
    static func fitted(_ text: String, to limit: CGFloat) -> String {
        guard width(of: text) > limit else { return text }
        var keep = text.count - 1
        while keep > 4 {
            let head = keep / 2 + keep % 2
            let candidate = String(text.prefix(head)) + "…" + String(text.suffix(keep - head))
            if width(of: candidate) <= limit { return candidate }
            keep -= 1
        }
        return String(text.prefix(2)) + "…"
    }

    static func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
    }

    /// Breaks `text` into lines that each fit `limit`, so a long detail line
    /// wraps instead of stretching the menu.
    ///
    /// Breaks at spaces and at the separators project names actually use, so
    /// `com.docker.backend · pid 36878 · 0.0.0.0` splits at its middots and
    /// `northwind-customer-dashboard-db` at a hyphen — never mid-word, unless
    /// a single run is itself too long to fit.
    static func wrapped(_ text: String, to limit: CGFloat) -> [String] {
        guard width(of: text) > limit else { return [text] }

        var lines: [String] = []
        var line = ""
        for token in tokens(of: text) {
            let candidate = line + token
            if line.isEmpty || width(of: trailingTrimmed(candidate)) <= limit {
                line = candidate
            } else {
                lines.append(trailingTrimmed(line))
                // Leading only. Trimming both ends here ate the *trailing*
                // space of a token like "pid ", fusing the next one into
                // "pid36878".
                line = leadingTrimmed(token)
            }
            // A single run with no break points in it, still too wide.
            while width(of: trailingTrimmed(line)) > limit, line.count > 1 {
                let split = hardSplit(trailingTrimmed(line), to: limit)
                lines.append(split.head)
                line = split.rest
            }
        }
        if !trailingTrimmed(line).isEmpty { lines.append(trailingTrimmed(line)) }
        return lines
    }

    /// Each token keeps its trailing separator, so joining tokens reproduces the
    /// original string exactly and a break lands *after* the separator.
    private static func tokens(of text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if " -_/.".contains(character) {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func hardSplit(_ text: String, to limit: CGFloat) -> (head: String, rest: String) {
        var count = text.count - 1
        while count > 1 {
            let head = String(text.prefix(count))
            if width(of: head) <= limit {
                return (head, String(text.dropFirst(count)))
            }
            count -= 1
        }
        return (String(text.prefix(1)), String(text.dropFirst(1)))
    }

    private static func trailingTrimmed(_ text: String) -> String {
        var out = text
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    private static func leadingTrimmed(_ text: String) -> String {
        String(text.drop(while: { $0 == " " }))
    }
}
