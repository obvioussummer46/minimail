import Foundation

/// Locale-aware formatting helpers that must work off the main actor: queries call them on GRDB reader threads.
nonisolated enum Formatters {
    /// Human byte count, e.g. `1.5 MB` in en_US and `1,5 MB` in de_DE. Negative counts are treated as zero.
    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(count, 0)), countStyle: .file)
    }
}
