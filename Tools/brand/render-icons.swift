// Renders every app icon from the in-app vector mark so the icons and `BrandMark` never drift.
//
//   swiftc -parse-as-library Packages/StrandDesign/Sources/StrandDesign/NaraMarkShape.swift \
//       Tools/brand/render-icons.swift -o /tmp/render-icons && /tmp/render-icons .
//
// Run from the repo root (or pass it as the first argument). iOS and watchOS icons are written opaque;
// App Store Connect rejects an icon with an alpha channel.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

let lavenderWhite = Color(red: 253 / 255, green: 247 / 255, blue: 255 / 255)
let deepIndigo = Color(red: 11 / 255, green: 2 / 255, blue: 38 / 255)

struct SquareIcon: View {
    var background: Color
    var ink: Color
    var markFraction: CGFloat = 0.56

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background
                NaraMarkShape()
                    .fill(ink)
                    .frame(width: geo.size.width * markFraction, height: geo.size.width * markFraction)
            }
        }
    }
}

/// macOS icons carry their own rounded-square plate inside the standard 824/1024 grid.
struct MacIcon: View {
    var body: some View {
        GeometryReader { geo in
            let plate = geo.size.width * 824 / 1024
            ZStack {
                RoundedRectangle(cornerRadius: plate * 0.225, style: .continuous)
                    .fill(deepIndigo)
                    .frame(width: plate, height: plate)
                    .shadow(color: .black.opacity(0.28), radius: geo.size.width * 0.012, y: geo.size.width * 0.008)
                NaraMarkShape()
                    .fill(lavenderWhite)
                    .frame(width: plate * 0.56, height: plate * 0.56)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

@MainActor
func write<V: View>(_ view: V, px: Int, to url: URL, opaque: Bool) throws {
    let renderer = ImageRenderer(content: view.frame(width: CGFloat(px), height: CGFloat(px)))
    renderer.scale = 1
    guard let rendered = renderer.cgImage else { throw NSError(domain: "render", code: 1) }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: info) else { throw NSError(domain: "render", code: 2) }
    ctx.draw(rendered, in: CGRect(x: 0, y: 0, width: px, height: px))
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "render", code: 3) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "render", code: 4) }
    print("wrote \(url.path) (\(px)px)")
}

@main
struct RenderIcons {
    @MainActor
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
        func at(_ path: String) -> URL { root.appendingPathComponent(path) }

        let light = SquareIcon(background: lavenderWhite, ink: deepIndigo)
        let dark = SquareIcon(background: deepIndigo, ink: lavenderWhite)

        try write(light, px: 1024, to: at("StrandiOS/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png"), opaque: true)
        try write(dark, px: 1024, to: at("StrandiOS/Resources/Assets.xcassets/AppIcon-Navy.appiconset/icon_1024.png"), opaque: true)
        try write(dark, px: 1024, to: at("NOOPWatch/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png"), opaque: true)

        for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try write(MacIcon(), px: points * scale, to: at("Strand/Resources/Assets.xcassets/AppIcon.appiconset/\(name)"), opaque: false)
        }

        try write(SquareIcon(background: .white, ink: deepIndigo, markFraction: 0.9), px: 612,
                  to: URL(fileURLWithPath: "/tmp/nara-mark-check.png"), opaque: true)
    }
}
