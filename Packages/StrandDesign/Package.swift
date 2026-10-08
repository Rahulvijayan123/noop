// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StrandDesign",
    // The package carries its OWN string catalog (Sources/StrandDesign/Resources/Localizable.xcstrings).
    // defaultLocalization is what makes SPM build the localized resource bundle at all; every
    // String(localized:) in the package passes `bundle: .module` so lookups hit that catalog instead of
    // silently falling back to the host app's main bundle (where package-only keys do not exist).
    defaultLocalization: "en",
    platforms: [.macOS(.v13), .iOS(.v16), .watchOS(.v10)],
    products: [.library(name: "StrandDesign", targets: ["StrandDesign"])],
    // The Liquid Glass renderer (vendored, see Packages/AemiSDR/VENDORED.md). iOS only: the watch has no
    // backdrop blur to drive, and the macOS app keeps its solid surfaces.
    dependencies: [.package(path: "../AemiSDR")],
    targets: [
        .target(
            name: "StrandDesign",
            dependencies: [.product(name: "AemiSDR", package: "AemiSDR", condition: .when(platforms: [.iOS]))],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "StrandDesignTests", dependencies: ["StrandDesign"]),
    ]
)
