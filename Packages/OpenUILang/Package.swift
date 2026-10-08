// swift-tools-version:5.9
import PackageDescription

// A Swift port of OpenUI Lang's core (`@openuidev/lang-core`, https://github.com/thesysdev/openui, MIT):
// the lexer, parser, streaming parser, schema-aware materializer, evaluator, built-ins, action plans and the
// system-prompt generator. Foundation only, so the parser and its tests run anywhere the app's shared code
// does; the SwiftUI renderer lives in the app. See PORTED.md for the upstream commit and what differs.
let package = Package(
    name: "OpenUILang",
    platforms: [.macOS(.v13), .iOS(.v16), .watchOS(.v10)],
    products: [.library(name: "OpenUILang", targets: ["OpenUILang"])],
    targets: [
        .target(name: "OpenUILang"),
        .testTarget(name: "OpenUILangTests", dependencies: ["OpenUILang"]),
    ]
)
