import Foundation

public enum PlainText {
    /// Swaps typographic punctuation for the plain keyboard characters, so text typed
    /// key by key (into a remote desktop) doesn't lose smart quotes, dashes or ellipses.
    public static func keyboardFriendly(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{2032}": out.append("'")
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{2033}": out.append("\"")
            case "\u{2013}", "\u{2014}", "\u{2212}": out.append("-")
            case "\u{2026}": out.append("...")
            case "\u{00A0}", "\u{2007}", "\u{202F}": out.append(" ")
            case "\r\n", "\r": out.append("\n")
            default: out.append(ch)
            }
        }
        return out
    }
}
