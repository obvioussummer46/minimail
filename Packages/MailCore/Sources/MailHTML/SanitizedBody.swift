import Foundation

public enum DarkStrategy: String, Sendable, Codable { case plain, card, native }

/// The output of module 08's sanitizer; declared here so `BodyRepository` (06) can store it before 08 exists.
public struct SanitizedBody: Sendable, Equatable {
    public var html: String
    public var hasRemoteImages: Bool
    public var darkStrategy: DarkStrategy
    public var referencedContentIDs: Set<String>

    public init(html: String, hasRemoteImages: Bool, darkStrategy: DarkStrategy, referencedContentIDs: Set<String>) {
        self.html = html
        self.hasRemoteImages = hasRemoteImages
        self.darkStrategy = darkStrategy
        self.referencedContentIDs = referencedContentIDs
    }
}
