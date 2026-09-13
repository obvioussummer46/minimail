import Foundation
import SwiftSoup

/// The `[html-rendering §1.5]` tracking-pixel heuristic: a remote image with an empty `alt` that is either tiny
/// (≤ 2 px on a side) or hidden. Never true for `cid:`/`data:` images.
public enum TrackingPixel {
    public static func isTracking(_ img: Element, src: String) -> Bool {
        let lower = src.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }

        let alt = ((try? img.attr("alt")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard alt.isEmpty else { return false }

        let style = ((try? img.attr("style")) ?? "").lowercased()
        let widthAttr = (try? img.attr("width")) ?? ""
        let heightAttr = (try? img.attr("height")) ?? ""
        let w = pixels(widthAttr) ?? cssPixels(style: style, property: "width")
        let h = pixels(heightAttr) ?? cssPixels(style: style, property: "height")
        let tiny = (w != nil && w! <= 2) || (h != nil && h! <= 2)

        let compact = String(style.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        let hidden =
            compact.contains("display:none") || compact.contains("visibility:hidden") || opacityZero(compact)
        return tiny || hidden
    }

    /// `"12"`, `"12px"`, `" 12 "` → 12; `"50%"`, `"auto"`, `""`, non-numeric → nil. Negative → 0.
    public static func pixels(_ attributeValue: String) -> Int? {
        var value = attributeValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.count >= 2 {
            let suffix = value.suffix(2).lowercased()
            if suffix == "px" { value = String(value.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        }
        guard let n = Int(value) else { return nil }
        return n < 0 ? 0 : n
    }

    /// Parses `style` as `;`-separated declarations; returns `pixels(value)` of the declaration whose name
    /// (trimmed, lowercased) equals `property` exactly. Last matching declaration wins.
    public static func cssPixels(style: String, property: String) -> Int? {
        var result: Int? = nil
        for declaration in style.split(separator: ";", omittingEmptySubsequences: true) {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let name = declaration[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == property.lowercased() else { continue }
            let value = String(declaration[declaration.index(after: colon)...])
            if let px = pixels(value) { result = px }
        }
        return result
    }

    /// A declaration `opacity:<v>` (whitespace already removed) where `Double(v) == 0`.
    private static func opacityZero(_ compact: String) -> Bool {
        for declaration in compact.split(separator: ";", omittingEmptySubsequences: true) {
            guard declaration.hasPrefix("opacity:") else { continue }
            let value = String(declaration.dropFirst("opacity:".count))
            if let d = Double(value), d == 0 { return true }
        }
        return false
    }
}
