// swift-tools-version: 6.1
import PackageDescription

// Fallback if SwiftSoup does not build on Linux (UNVERIFIED): `MAILCORE_SKIP_HTML=1 swift test` omits MailHTML.
let includeHTML = Context.environment["MAILCORE_SKIP_HTML"] == nil

var products: [Product] = [.library(name: "MailCore", targets: ["MailCore"])]
var targets: [Target] = [
    .target(name: "MailCore", swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(name: "MailCoreTests", dependencies: ["MailCore"], resources: [.copy("Fixtures")]),
]
var dependencies: [Package.Dependency] = []
if includeHTML {
    products.append(.library(name: "MailHTML", targets: ["MailHTML"]))
    dependencies.append(.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9"))
    targets += [
        .target(name: "MailHTML", dependencies: ["MailCore", "SwiftSoup"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "MailHTMLTests", dependencies: ["MailHTML", "SwiftSoup"], resources: [.copy("Fixtures")]),
    ]
}
let package = Package(
    name: "MailCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
