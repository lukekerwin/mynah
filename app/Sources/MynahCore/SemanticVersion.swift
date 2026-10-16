import Foundation

/// Semantic-version precedence for release tags like `0.2.0-beta.10`:
/// 0.2.0-beta.2 < 0.2.0-beta.10 < 0.2.0-rc.1 < 0.2.0 < 0.2.1.
/// (Sparkle's built-in comparator orders pre-release suffixes wrongly.)
public enum SemanticVersion {
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let (coreA, preA) = split(a)
        let (coreB, preB) = split(b)
        for i in 0..<max(coreA.count, coreB.count) {
            let x = i < coreA.count ? coreA[i] : 0
            let y = i < coreB.count ? coreB[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        switch (preA.isEmpty, preB.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): break
        }
        for (x, y) in zip(preA, preB) where x != y {
            switch (Int(x), Int(y)) {
            case let (m?, n?): return m < n ? .orderedAscending : .orderedDescending
            case (.some, nil): return .orderedAscending
            case (nil, .some): return .orderedDescending
            case (nil, nil): return x < y ? .orderedAscending : .orderedDescending
            }
        }
        if preA.count == preB.count { return .orderedSame }
        return preA.count < preB.count ? .orderedAscending : .orderedDescending
    }

    /// "v1.2.3-beta.4+build" → ([1, 2, 3], ["beta", "4"])
    private static func split(_ version: String) -> (core: [Int], pre: [String]) {
        var v = Substring(version)
        if v.first == "v" { v = v.dropFirst() }
        if let plus = v.firstIndex(of: "+") { v = v[..<plus] }
        let parts = v.split(separator: "-", maxSplits: 1)
        let core = parts.first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        let pre = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        return (core, pre)
    }
}
