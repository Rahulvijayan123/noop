import Foundation
import SwiftUI
import UIKit

// Native port of thinking-orbs (MIT, Jakub Antalík): dotted thought-orbs for
// AI status. Geometry matches the JS engine. Drawn in a UIView + CADisplayLink
// because SwiftUI Canvas does not redraw from Timer/@Published ticks inside a
// LazyVStack — it keeps the first frame, which looked frozen.

enum OrbState: String, CaseIterable {
    case working, searching, solving, listening, connecting
    case weaving, composing, breathing, shaping

    var accessibilityLabel: String {
        switch self {
        case .working: return "Working…"
        case .searching: return "Searching…"
        case .solving: return "Solving…"
        case .listening: return "Listening…"
        case .connecting: return "Connecting…"
        case .weaving: return "Weaving…"
        case .composing: return "Composing…"
        case .breathing: return "Thinking…"
        case .shaping: return "Shaping…"
        }
    }
}

enum OrbTheme {
    case auto, dark, light
}

struct ThinkingOrb: View {
    /// Inline preset from thinking-orbs (`size={20}`), not the 64px avatar graphic.
    static let indicatorSize: CGFloat = 20

    var state: OrbState = .solving
    var size: CGFloat = Self.indicatorSize
    var theme: OrbTheme = .auto
    var speed: Double = 1
    var paused: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dark = theme == .dark || (theme == .auto && colorScheme == .dark)
        OrbImageView(
            state: state,
            size: size,
            speed: reduceMotion ? speed * 0.45 : speed,
            dark: dark,
            paused: paused
        )
        .frame(width: size, height: size)
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityAddTraits(.isImage)
        .allowsHitTesting(false)
    }
}

/// Renders into a UIImageView from CADisplayLink. SwiftUI Canvas and UIView.draw(_:)
/// both drop frames inside LazyVStack; assigning `image` does not.
private struct OrbImageView: UIViewRepresentable {
    var state: OrbState
    var size: CGFloat
    var speed: Double
    var dark: Bool
    var paused: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        context.coordinator.imageView = view
        context.coordinator.apply(state: state, size: size, speed: speed, dark: dark, paused: paused)
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        context.coordinator.imageView = uiView
        context.coordinator.apply(state: state, size: size, speed: speed, dark: dark, paused: paused)
    }

    static func dismantleUIView(_ uiView: UIImageView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        weak var imageView: UIImageView?
        private var displayLink: CADisplayLink?
        private var startedAt: CFTimeInterval = CACurrentMediaTime()
        private let proxy = TickProxy()
        private var state: OrbState = .solving
        private var size: CGFloat = ThinkingOrb.indicatorSize
        private var speed: Double = 1
        private var dark = true
        private var paused = false

        fileprivate final class TickProxy: NSObject {
            weak var owner: Coordinator?
            @objc func tick(_ link: CADisplayLink) { owner?.render() }
        }

        init() { proxy.owner = self }

        deinit { displayLink?.invalidate() }

        func apply(state: OrbState, size: CGFloat, speed: Double, dark: Bool, paused: Bool) {
            self.state = state
            self.size = size
            self.speed = speed
            self.dark = dark
            let wasPaused = self.paused
            self.paused = paused
            if wasPaused != paused {
                paused ? stop() : start()
            }
        }

        func start() {
            guard displayLink == nil, !paused else { return }
            startedAt = CACurrentMediaTime()
            let link = CADisplayLink(target: proxy, selector: #selector(TickProxy.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
            render()
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
            render()
        }

        private func render() {
            let side = max(size, 1)
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            format.scale = UIScreen.main.scale
            let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
                let preset = OrbEngine.resolve(state: state, size: side)
                let t = paused
                    ? 0.6
                    : (CACurrentMediaTime() - startedAt) * preset.speed * speed
                let frame = OrbEngine.frame(mode: preset.mode, size: side, t: t, opts: preset.opts)
                OrbEngine.paint(frame, dark: dark, in: ctx.cgContext)
            }
            imageView?.image = image
        }
    }
}

// MARK: - Engine

enum OrbEngine {
    struct Dot {
        var x: Double
        var y: Double
        var z: Double
        var r: Double
        var white: Double
        var a: Double
    }

    struct Line {
        var x1: Double
        var y1: Double
        var x2: Double
        var y2: Double
        var white: Double
        var a: Double
        var w: Double
    }

    struct Frame {
        var dots: [Dot]
        var lines: [Line]
    }

    struct Opts {
        var latRings = 17.0
        var lonDensity = 44.0
        var rings = 15.0
        var lanes = 5.0
        var segs = 88.0
        var orbitN = 12.0
        var ghostN = 40.0
        var nodeN = 30.0
        var strandN = 52.0
        var signals = 5.0
        var iconD = 1.0
        var rBase = 0.6
        var rDepth = 1.7
        var rActive = 0.3
        var rDot = 0.021
        var ghostR = 0.9
        var partR = 1.2
        var partRDepth = 1.6
        var nodeR = 1.4
        var nodeRDepth = 1.8
        var rBoost = 1.0
        var inkFar = 0.62
        var inkSpan = 0.54
        var ghostA = 0.5
        var particles = 3.0
        var rsPow = 0.6
        var rMin = 0.3
        var thr = 0.72
        var lineW = 0.8
        var turns = 3.0
        var spin = 1.0
        var bandMul = 1.0
        var wobMul = 1.0
        var faceOn = 0.0
        var spread = 1.0
        var scanMul = 1.0
        var dimBase = 1.0
        var moveCount = 14.0
        var rSizeMul = 1.0
    }

    struct Resolved {
        var mode: Mode
        var speed: Double
        var opts: Opts
    }

    enum Mode {
        case orbits, globe, rubik, wave, web, braid, ribbon, ring, morph
    }

    static func resolve(state: OrbState, size: CGFloat) -> Resolved {
        let presetSize: CGFloat = size <= 32 ? 20 : 64
        let mode = mode(for: state)
        var opts = baseProfile(mode)
        let preset = presets[mode]![presetSize == 20 ? 20 : 64]!
        if preset.count != 1 { opts = scaleCounts(opts, preset.count, mode: mode) }
        if preset.size != 1 { opts = scaleRadii(opts, preset.size) }
        if let extra = preset.extra { extra(&opts) }
        return Resolved(mode: mode, speed: preset.speed, opts: opts)
    }

    static func frame(state: OrbState, size: CGFloat, t: Double) -> Frame {
        let resolved = resolve(state: state, size: size)
        return frame(mode: resolved.mode, size: size, t: t, opts: resolved.opts)
    }

    static func frame(mode: Mode, size: CGFloat, t: Double, opts: Opts) -> Frame {
        switch mode {
        case .orbits: return frameOrbits(size, t, opts)
        case .globe: return frameGlobe(size, t, opts)
        case .rubik: return frameRubik(size, t, opts)
        case .wave: return frameWave(size, t, opts)
        case .web: return frameWeb(size, t, opts)
        case .braid: return frameBraid(size, t, opts)
        case .ribbon, .ring: return frameRibbon(size, t, opts)
        case .morph: return frameMorph(size, t, opts)
        }
    }

    static func paint(_ frame: Frame, dark: Bool, in ctx: CGContext) {
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for line in frame.lines {
            let ink = dark ? 1 - line.white : line.white
            ctx.setStrokeColor(gray: CGFloat(clamp01(ink)), alpha: CGFloat(line.a))
            ctx.setLineWidth(CGFloat(max(line.w, 0.6)))
            ctx.move(to: CGPoint(x: line.x1, y: line.y1))
            ctx.addLine(to: CGPoint(x: line.x2, y: line.y2))
            ctx.strokePath()
        }
        for dot in frame.dots {
            let ink = dark ? 1 - dot.white : dot.white
            ctx.setFillColor(gray: CGFloat(clamp01(ink)), alpha: CGFloat(dot.a))
            let r = max(dot.r, 0.6)
            ctx.fillEllipse(in: CGRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2))
        }
    }

    // MARK: Presets

    private struct Preset {
        var speed: Double
        var count: Double
        var size: Double
        var extra: ((inout Opts) -> Void)?
    }

    private static let presets: [Mode: [Int: Preset]] = [
        .orbits: [
            64: Preset(speed: 1.885, count: 1, size: 1),
            20: Preset(speed: 3.9, count: 0.238, size: 2.4)
        ],
        .globe: [
            64: Preset(speed: 2.015, count: 0.42, size: 1.15, extra: { $0.scanMul = 4.08; $0.dimBase = 0.45 }),
            20: Preset(speed: 2.665, count: 0.32, size: 1.75, extra: { $0.scanMul = 4.335; $0.dimBase = 0.45 })
        ],
        .rubik: [
            64: Preset(speed: 1.82, count: 0.35, size: 1.05),
            20: Preset(speed: 1.95, count: 0.22, size: 1.9)
        ],
        .wave: [
            64: Preset(speed: 4.388, count: 0.341, size: 1),
            20: Preset(speed: 3.998, count: 0.105, size: 1.6)
        ],
        .web: [
            64: Preset(speed: 3.315, count: 1.35, size: 0.95),
            20: Preset(speed: 6.63, count: 0.55, size: 1.52)
        ],
        .braid: [
            64: Preset(speed: 1.625, count: 0.5, size: 1),
            20: Preset(speed: 2.75, count: 0.1125, size: 1.36)
        ],
        .ribbon: [
            64: Preset(speed: 2.34, count: 0.25, size: 0.85, extra: { $0.spin = 0; $0.bandMul = 3.9; $0.wobMul = 1 }),
            20: Preset(speed: 3.12, count: 0.051, size: 1.073, extra: { $0.spin = 0; $0.bandMul = 4.94; $0.wobMul = 1 })
        ],
        .ring: [
            64: Preset(speed: 3.24, count: 0.25, size: 0.956, extra: { $0.spin = 0; $0.bandMul = 3.627; $0.wobMul = 0.368 }),
            20: Preset(speed: 3.78, count: 0.028, size: 1.622, extra: { $0.spin = 0; $0.bandMul = 3.968; $0.wobMul = 0.565 })
        ],
        .morph: [
            64: Preset(speed: 2.405, count: 0.702, size: 0.395, extra: { $0.spread = 1.45 }),
            20: Preset(speed: 2.08, count: 0.53, size: 1.011, extra: { $0.spread = 1.45 })
        ]
    ]

    private static func mode(for state: OrbState) -> Mode {
        switch state {
        case .working: return .orbits
        case .searching: return .globe
        case .solving: return .rubik
        case .listening: return .wave
        case .connecting: return .web
        case .weaving: return .braid
        case .composing: return .ribbon
        case .breathing: return .ring
        case .shaping: return .morph
        }
    }

    private static func baseProfile(_ mode: Mode) -> Opts {
        var o = Opts()
        switch mode {
        case .globe:
            break
        case .orbits:
            o.orbitN = 12; o.ghostN = 40; o.ghostR = 0.9; o.ghostA = 0.5
            o.particles = 3; o.partR = 1.2; o.partRDepth = 1.6
        case .rubik:
            o.latRings = 15; o.lonDensity = 40; o.moveCount = 14; o.rActive = 0.3
        case .wave:
            o.rings = 15; o.lonDensity = 40
        case .web:
            o.nodeN = 30; o.thr = 0.72; o.signals = 5
            o.nodeR = 1.4; o.nodeRDepth = 1.8; o.lineW = 0.8
        case .braid:
            o.strandN = 52; o.turns = 3; o.ghostN = 150
            o.rBase = 1.2; o.rDepth = 1.8
        case .ribbon:
            o.lanes = 5; o.segs = 88; o.ghostN = 150
            o.rBase = 1.1; o.rDepth = 1.7
        case .ring:
            o.lanes = 5; o.segs = 88; o.ghostN = 0; o.faceOn = 1
            o.rBase = 1.1; o.rDepth = 1.7
        case .morph:
            o.rDot = 0.021; o.iconD = 1; o.rMin = 0.25
        }
        return o
    }

    private static func scaleCounts(_ opts: Opts, _ scale: Double, mode: Mode) -> Opts {
        var out = opts
        let rt = sqrt(scale)
        switch mode {
        case .globe, .rubik:
            out.latRings = max(2, (out.latRings * rt).rounded())
            out.lonDensity = max(2, (out.lonDensity * rt).rounded())
        case .wave:
            out.rings = max(2, (out.rings * rt).rounded())
            out.lonDensity = max(2, (out.lonDensity * rt).rounded())
        case .ribbon, .ring:
            out.lanes = max(2, (out.lanes * rt).rounded())
            out.segs = max(2, (out.segs * rt).rounded())
        default:
            break
        }
        func scaled(_ v: Double) -> Double {
            v == 0 ? 0 : max(1, (v * scale).rounded())
        }
        switch mode {
        case .orbits:
            out.orbitN = scaled(out.orbitN)
            out.ghostN = scaled(out.ghostN)
        case .web:
            out.nodeN = scaled(out.nodeN)
            out.signals = scaled(out.signals)
        case .braid:
            out.strandN = scaled(out.strandN)
            out.ghostN = scaled(out.ghostN)
        case .ribbon:
            out.ghostN = scaled(out.ghostN)
        case .morph:
            out.iconD = max(0.02, out.iconD * scale)
        default:
            break
        }
        return out
    }

    private static func scaleRadii(_ opts: Opts, _ scale: Double) -> Opts {
        var out = opts
        out.rBase *= scale
        out.rDepth *= scale
        out.rActive *= scale
        out.rDot *= scale
        out.ghostR *= scale
        out.partR *= scale
        out.partRDepth *= scale
        out.nodeR *= scale
        out.nodeRDepth *= scale
        out.rSizeMul *= scale
        return out
    }

    // MARK: Core math

    private static func lerp(_ a: Double, _ b: Double, _ f: Double) -> Double { a + (b - a) * f }
    private static func frac(_ x: Double) -> Double { x - floor(x) }
    private static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

    private static func hashD(_ a: Double, _ b: Double) -> Double {
        let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
        return h - floor(h)
    }

    private static func vnoise(_ x: Double, _ y: Double) -> Double {
        let xi = floor(x)
        let yi = floor(y)
        var fx = x - xi
        var fy = y - yi
        fx = fx * fx * (3 - 2 * fx)
        fy = fy * fy * (3 - 2 * fy)
        let a = hashD(xi, yi)
        let b = hashD(xi + 1, yi)
        let c = hashD(xi, yi + 1)
        let d = hashD(xi + 1, yi + 1)
        return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy
    }

    private static func fibDir(_ i: Double, _ n: Double) -> (Double, Double, Double) {
        let golden = Double.pi * (3 - sqrt(5))
        let y = 1 - (2 * (i + 0.5)) / n
        let rad = sqrt(max(0, 1 - y * y))
        let a = i * golden
        return (rad * cos(a), y, rad * sin(a))
    }

    private static func angleDelta(_ a: Double, _ b: Double) -> Double {
        atan2(sin(a - b), cos(a - b))
    }

    private static func radiusScale(_ size: CGFloat, _ exponent: Double) -> Double {
        Foundation.pow(Double(size) / 300, exponent)
    }

    private typealias Projector = (Double, Double, Double) -> (Double, Double, Double)

    private static func makeProj(
        _ yaw: Double, _ tilt: Double, _ cx: Double, _ cy: Double, _ scale: Double
    ) -> Projector {
        let st = sin(tilt), ct = cos(tilt), sy = sin(yaw), cyw = cos(yaw)
        return { x, y, z in
            let x1 = x * cyw + z * sy
            let z1 = -x * sy + z * cyw
            let y1 = y * ct - z1 * st
            let z2 = y * st + z1 * ct
            return (cx + x1 * scale, cy - y1 * scale, z2)
        }
    }

    private static func finalize(_ dots: [Dot], _ lines: [Line], _ rMin: Double) -> Frame {
        var visible = dots.compactMap { d -> Dot? in
            guard d.a >= 0.02 else { return nil }
            var copy = d
            copy.r = max(rMin, d.r)
            return copy
        }
        visible.sort { $0.z < $1.z }
        return Frame(dots: visible, lines: lines.filter { $0.a >= 0.02 })
    }

    // MARK: Modes

    private static func frameWeb(_ size: CGFloat, _ t: Double, _ o: Opts) -> Frame {
        let cx = Double(size) / 2
        let cy = Double(size) / 2
        let R = (Double(size) / 2) * 0.8 * o.spread
        let pt = makeProj(t * 0.12, 0.32, cx, cy, R)
        let rs = radiusScale(size, o.rsPow)
        let nodeN = Int(o.nodeN)
        var nodes: [(Double, Double, Double)] = []
        nodes.reserveCapacity(nodeN)
        for i in 0..<nodeN {
            let d = fibDir(Double(i), Double(nodeN))
            let x = d.0 + 0.3 * (vnoise(Double(i) * 0.31 + 9, t * 0.24) - 0.5) * 2
            let y = d.1 + 0.3 * (vnoise(Double(i) * 0.53 + 27, t * 0.21) - 0.5) * 2
            let z = d.2 + 0.3 * (vnoise(Double(i) * 0.77 + 55, t * 0.27) - 0.5) * 2
            let l = max(1e-6, sqrt(x * x + y * y + z * z))
            nodes.append((x / l, y / l, z / l))
        }

        var lines: [Line] = []
        var dots: [Dot] = []
        for i in 0..<nodeN {
            for j in (i + 1)..<nodeN {
                let dx = nodes[i].0 - nodes[j].0
                let dy = nodes[i].1 - nodes[j].1
                let dz = nodes[i].2 - nodes[j].2
                let dist = sqrt(dx * dx + dy * dy + dz * dz)
                guard dist < o.thr else { continue }
                let p1 = pt(nodes[i].0, nodes[i].1, nodes[i].2)
                let p2 = pt(nodes[j].0, nodes[j].1, nodes[j].2)
                let depth = ((p1.2 + p2.2) / 2 + 1) / 2
                lines.append(Line(
                    x1: p1.0, y1: p1.1, x2: p2.0, y2: p2.1,
                    white: 0.42,
                    a: (1 - dist / o.thr) * (0.3 + 0.55 * depth),
                    w: max(0.6, o.lineW * rs)
                ))
            }
        }
        for i in 0..<nodeN {
            let p = pt(nodes[i].0, nodes[i].1, nodes[i].2)
            let depth = (p.2 + 1) / 2
            let pulse = 1 + 0.25 * sin(t * 1.4 + Double(i) * 2.7)
            dots.append(Dot(
                x: p.0, y: p.1, z: p.2,
                r: (o.nodeR + o.nodeRDepth * depth) * pulse * rs,
                white: 0.55 - 0.45 * depth,
                a: 1
            ))
        }
        let signals = Int(o.signals)
        for s in 0..<signals {
            let seg = floor(t * 0.55 + Double(s) * 7.31)
            let a = Int(floor(hashD(seg, Double(s) * 3.1 + 1.7) * Double(nodeN)))
            let b = Int(floor(hashD(seg, Double(s) * 5.7 + 4.2) * Double(nodeN)))
            guard a != b, nodes.indices.contains(a), nodes.indices.contains(b) else { continue }
            let f = frac(t * 0.55 + Double(s) * 7.31)
            let x = lerp(nodes[a].0, nodes[b].0, f)
            let y = lerp(nodes[a].1, nodes[b].1, f)
            let z = lerp(nodes[a].2, nodes[b].2, f)
            let l = max(1e-6, sqrt(x * x + y * y + z * z))
            let p = pt(x / l, y / l, z / l)
            let depth = (p.2 + 1) / 2
            dots.append(Dot(
                x: p.0, y: p.1, z: p.2,
                r: (o.nodeR * 1.5 + o.nodeRDepth * depth) * rs,
                white: 0.05,
                a: 0.5 + 0.5 * depth
            ))
        }
        return finalize(dots, lines, o.rMin)
    }

    private static func frameOrbits(_ size: CGFloat, _ t: Double, _ o: Opts) -> Frame {
        let cx = Double(size) / 2
        let cy = Double(size) / 2
        let R = (Double(size) / 2) * 0.82
        let pt = makeProj(t * 0.12, 0.3, cx, cy, 1)
        let rs = radiusScale(size, o.rsPow)
        var dots: [Dot] = []
        let orbitN = Int(o.orbitN)
        let ghostN = Int(o.ghostN)
        let particles = Int(o.particles)
        for orb in 0..<orbitN {
            let h1 = hashD(Double(orb), 1.7)
            let h2 = hashD(Double(orb), 5.2)
            let h3 = hashD(Double(orb), 8.9)
            let ro = R * (0.45 + 0.52 * h1)
            let th = h1 * 2 * Double.pi
            let phi = acos(2 * h2 - 1)
            let nx = sin(phi) * cos(th)
            let ny = cos(phi)
            let nz = sin(phi) * sin(th)
            var ux = -ny
            var uy = nx
            let ul = max(1e-6, sqrt(ux * ux + uy * uy))
            ux /= ul
            uy /= ul
            let vx = ny * 0 - nz * uy
            let vy = nz * ux - nx * 0
            let vz = nx * uy - ny * ux
            let speed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1.0 : -1.0)
            for k in 0..<ghostN {
                let a = (Double(k) / Double(ghostN)) * 2 * Double.pi
                let p = pt(
                    (ux * cos(a) + vx * sin(a)) * ro,
                    (uy * cos(a) + vy * sin(a)) * ro,
                    (0 * cos(a) + vz * sin(a)) * ro
                )
                let depth = (p.2 / ro + 1) / 2
                dots.append(Dot(
                    x: p.0, y: p.1, z: p.2,
                    r: o.ghostR * rs,
                    white: 0.72,
                    a: o.ghostA * (0.4 + 0.6 * depth)
                ))
            }
            for m in 0..<particles {
                let a = t * speed + (Double(m) / Double(particles)) * 2 * Double.pi + h2 * 6
                let p = pt(
                    (ux * cos(a) + vx * sin(a)) * ro,
                    (uy * cos(a) + vy * sin(a)) * ro,
                    (0 * cos(a) + vz * sin(a)) * ro
                )
                let depth = (p.2 / ro + 1) / 2
                dots.append(Dot(
                    x: p.0, y: p.1, z: p.2,
                    r: (o.partR + o.partRDepth * depth) * rs,
                    white: 0.3 - 0.22 * depth,
                    a: 1
                ))
            }
        }
        return finalize(dots, [], o.rMin)
    }

    private static func frameGlobe(_ size: CGFloat, _ t: Double, _ o: Opts) -> Frame {
        let spin = 0.5
        let cx = Double(size) / 2
        let cy = Double(size) / 2
        let radius = (Double(size) / 2) * 0.82
        let tilt = 0.4 + 0.06 * sin(t * 0.35)
        let pt = makeProj(t * spin, tilt, cx, cy, radius)
        let scan = t * (spin + (1.7 - spin) * o.scanMul)
        let rs = radiusScale(size, o.rsPow)
        var dots: [Dot] = []
        let latRings = Int(o.latRings)
        let lonDensity = o.lonDensity
        for li in 0...latRings {
            let lat = -Double.pi / 2 + (Double(li) / Double(latRings)) * Double.pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let lonCount = max(1, Int((abs(cosLat) * lonDensity).rounded()))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * Double.pi
                let p = pt(cosLat * cos(lon), sinLat, cosLat * sin(lon))
                let depth = (p.2 + 1) / 2
                let d = angleDelta(lon + t * spin, scan)
                let boost = exp(-(d * d) / 0.18) * max(0, p.2)
                dots.append(Dot(
                    x: p.0, y: p.1, z: p.2,
                    r: (o.rBase + o.rDepth * depth + o.rBoost * boost) * rs,
                    white: o.inkFar - o.inkSpan * depth,
                    a: o.dimBase + (1 - o.dimBase) * min(1, boost)
                ))
            }
        }
        return finalize(dots, [], o.rMin)
    }

    private static func frameRubik(_ size: CGFloat, _ t: Double, _ o: Opts) -> Frame {
        let cx = Double(size) / 2
        let cy = Double(size) / 2
        let R = (Double(size) / 2) * 0.82
        let pt = makeProj(t * 0.55, 0.35 + 0.1 * sin(t * 0.9), cx, cy, R)
        let rs = radiusScale(size, o.rsPow)
        let moveCount = Int(o.moveCount)
        let moves = makeMoves(moveCount)
        let sc = solveCycle(t, moveCount, 0.42, 1.2)
        var dots: [Dot] = []
        let latRings = Int(o.latRings)
        let lonDensity = o.lonDensity
        for li in 0...latRings {
            let lat = -Double.pi / 2 + (Double(li) / Double(latRings)) * Double.pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let lonCount = max(1, Int((abs(cosLat) * lonDensity).rounded()))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * Double.pi
                let moved = applyMoves(
                    (cosLat * cos(lon), sinLat, cosLat * sin(lon)),
                    moves,
                    sc
                )
                let p = pt(moved.0, moved.1, moved.2)
                let depth = (p.2 + 1) / 2
                dots.append(Dot(
                    x: p.0, y: p.1, z: p.2,
                    r: (o.rBase + o.rDepth * depth + (moved.3 ? o.rActive : 0)) * rs,
                    white: o.inkFar - o.inkSpan * depth - (moved.3 ? 0.14 : 0),
                    a: 1
                ))
            }
        }
        return finalize(dots, [], o.rMin)
    }

    private static func frameWave(_ size: CGFloat, _ t: Double, _ o: Opts) -> Frame {
        let cx = Double(size) / 2
        let cy = Double(size) / 2
        let R = (Double(size) / 2) * 0.874
        let pt = makeProj(t * 0.18, 0.38, cx, cy, 1)
        let rs = radiusScale(size, o.rsPow)
        var dots: [Dot] = []
        let rings = Int(o.rings)
        let lonDensity = o.lonDensity
        for ri in 0...rings {
            let lat = -Double.pi / 2 + (Double(ri) / Double(rings)) * Double.pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let w = 0.62 * sin(t * 2.1 - Double(ri) * 0.52) + 0.38 * sin(t * 1.27 + Double(ri) * 0.83)
            let rr = R * (0.88 + 0.105 * w)
            let lonCount = max(1, Int((abs(cosLat) * lonDensity).rounded()))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * Double.pi
                let p = pt(cosLat * cos(lon) * rr, sinLat * rr, cosLat * sin(lon) * rr)
                let depth = (p.2 / R + 1) / 2
                let crest = max(0, w)
                dots.append(Dot(
                    x: p.0, y: p.1, z: p.2,
                    r: (o.rBase + o.rDepth * depth) * (1 + 0.4 * crest) * rs,
                    white: 0.66 - 0.56 * depth - 0.1 * crest,
                    a: 1
                ))
            }
        }
        return finalize(dots, [], o.rMin)
    }

    private static func frameBraid(_ size: CGFloat, _ t: Double, _ o: Opts) -> Frame {
        let cx = Double(size) / 2
        let cy = Double(size) / 2
        let R = (Double(size) / 2) * 0.76
        let pt = makeProj(t * 0.4, 0.3, cx, cy, 1)
        let rs = radiusScale(size, o.rsPow)
        var dots: [Dot] = []
        let ghostN = Int(o.ghostN)
        for i in 0..<ghostN {
            let d = fibDir(Double(i), Double(ghostN))
            let p = pt(d.0 * R, d.1 * R, d.2 * R)
            let depth = (p.2 / R + 1) / 2
            dots.append(Dot(x: p.0, y: p.1, z: p.2, r: 0.8 * rs, white: 0.78, a: 0.1 + 0.22 * depth))
        }
        let strandN = Int(o.strandN)
        let turns = o.turns
        for s in 0..<3 {
            let phase = (Double(s) / 3) * 2 * Double.pi
            for i in 0..<strandN {
                let u = (frac(Double(i) / Double(strandN) + t * 0.045) * 2 - 1) * 0.96
                let surf = sqrt(max(0, 1 - u * u))
                let endFade = min(1, (1 - abs(u)) / 0.1)
                let a = u * Double.pi * turns + phase
                let weave = 1 + 0.075 * sin(u * Double.pi * turns * 2 + phase * 2 + t * 0.8)
                let rr = surf * R * weave
                let p = pt(cos(a) * rr, u * R * weave, sin(a) * rr)
                let depth = (p.2 / R + 1) / 2
                dots.append(Dot(
                    x: p.0, y: p.1, z: p.2,
                    r: (o.rBase + o.rDepth * depth) * rs,
                    white: 0.55 - 0.45 * depth,
                    a: endFade * (0.45 + 0.55 * depth)
                ))
            }
        }
        return finalize(dots, [], o.rMin)
    }

    private static func frameRibbon(_ size: CGFloat, _ t: Double, _ o: Opts) -> Frame {
        let cx = Double(size) / 2
        let cy = Double(size) / 2
        let R = (Double(size) / 2) * 0.78
        let spin = o.spin
        let camTilt = 0.3
        let pt = makeProj(t * 0.1 * spin, camTilt, cx, cy, 1)
        let rs = radiusScale(size, o.rsPow)
        var dots: [Dot] = []
        let ghostN = Int(o.ghostN)
        for i in 0..<ghostN {
            let d = fibDir(Double(i), Double(ghostN))
            let p = pt(d.0 * R, d.1 * R, d.2 * R)
            let depth = (p.2 / R + 1) / 2
            dots.append(Dot(x: p.0, y: p.1, z: p.2, r: 0.8 * rs, white: 0.78, a: 0.1 + 0.22 * depth))
        }
        let ya = t * 0.24 * spin
        let ta = o.faceOn != 0 ? -camTilt : 0.55 + 0.3 * sin(t * 0.18) * spin
        let ux = cos(ya), uy = 0.0, uz = sin(ya)
        let vx = -uz * sin(ta), vy = cos(ta), vz = ux * sin(ta)
        let nx = uy * vz - uz * vy
        let ny = uz * vx - ux * vz
        let nz = ux * vy - uy * vx
        let wobAmp = 0.23 * o.wobMul
        let baseR = o.faceOn != 0 ? R / (1 + 0.85 * wobAmp) : R
        let baseLanes = o.lanes
        let segs = Int(o.segs)
        let lanes = max(1, Int((baseLanes * o.bandMul).rounded()))
        for w in 0..<lanes {
            let laneOff = (Double(w) - Double(lanes - 1) / 2) * 0.075
            let edge = abs(Double(w) - Double(lanes - 1) / 2) / max(1, Double(lanes - 1) / 2)
            for k in 0..<segs {
                let a = (Double(k) / Double(segs)) * 2 * Double.pi
                let wob = (0.16 * sin(a * 3 - t * 1.7 + Double(w) * 0.22) + 0.07 * sin(a * 5 + t * 1.1)) * o.wobMul
                let radial = o.faceOn != 0 ? 1 + wob : 1.0
                let off = o.faceOn != 0 ? laneOff : laneOff + wob
                let x = ux * cos(a) + vx * sin(a) + nx * off
                let y = uy * cos(a) + vy * sin(a) + ny * off
                let z = uz * cos(a) + vz * sin(a) + nz * off
                let l = max(1e-6, sqrt(x * x + y * y + z * z))
                let rr = baseR * radial
                let p = pt((x / l) * rr, (y / l) * rr, (z / l) * rr)
                let depth = (p.2 / R + 1) / 2
                dots.append(Dot(
                    x: p.0, y: p.1, z: p.2,
                    r: (o.rBase + o.rDepth * depth) * (1 - 0.25 * edge) * rs,
                    white: 0.52 - 0.44 * depth + 0.18 * edge,
                    a: 0.4 + 0.6 * depth
                ))
            }
        }
        return finalize(dots, [], o.rMin)
    }

    private static func frameMorph(_ size: CGFloat, _ t: Double, _ o: Opts) -> Frame {
        let cycle: [(Double) -> (Double, Double)] = [circlePath, trianglePath, squarePath]
        let hold = 1.4
        let morph = 0.9
        let segDur = hold + morph
        let kCount = cycle.count
        let tc = t.truncatingRemainder(dividingBy: segDur * Double(kCount))
        let k = Int(floor(tc / segDur))
        let local = tc - Double(k) * segDur
        let m = local > hold ? smoothE((local - hold) / morph) : 0
        let sprd = o.spread
        let pA = cycle[k]
        let pB = cycle[(k + 1) % kCount]
        let M = 160
        var pts: [(Double, Double)] = []
        pts.reserveCapacity(M)
        for i in 0..<M {
            let f = Double(i) / Double(M)
            let a = pA(f)
            let b = pB(f)
            pts.append(((a.0 + (b.0 - a.0) * m) * sprd, (a.1 + (b.1 - a.1) * m) * sprd))
        }
        var lengths: [Double] = []
        var total = 0.0
        for i in 0..<M {
            let a = pts[i]
            let b = pts[(i + 1) % M]
            let l = hypot(b.0 - a.0, b.1 - a.1)
            lengths.append(l)
            total += l
        }
        let n = max(6, Int((34 * o.iconD).rounded()))
        let re = o.rDot * 1.35 * sprd
        let pulse = 1 + 0.02 * sin(local * 3.1)
        var dots: [Dot] = []
        let c2 = Double(size) / 2
        var seg = 0
        var acc = 0.0
        for k2 in 0..<n {
            let target = (Double(k2) / Double(n)) * total
            while acc + lengths[seg] < target && seg < M - 1 {
                acc += lengths[seg]
                seg += 1
            }
            let a = pts[seg]
            let b = pts[(seg + 1) % M]
            let f = lengths[seg] == 0 ? 0 : min(1, (target - acc) / lengths[seg])
            let x = (a.0 + (b.0 - a.0) * f) * pulse
            let y = (a.1 + (b.1 - a.1) * f) * pulse
            dots.append(Dot(
                x: c2 + x * Double(size),
                y: c2 + y * Double(size),
                z: 0,
                r: max(0.35, re * Double(size)),
                white: 0.1,
                a: 1
            ))
        }
        return finalize(dots, [], o.rMin)
    }

    private static func smoothE(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    private static func circlePath(_ f: Double) -> (Double, Double) {
        let a = -Double.pi / 2 + f * 2 * Double.pi
        return (cos(a) * 0.24, sin(a) * 0.24)
    }

    private static func polyPath(_ verts: [(Double, Double)]) -> (Double) -> (Double, Double) {
        let v = verts.count
        var lengths: [Double] = []
        var total = 0.0
        for i in 0..<v {
            let a = verts[i]
            let b = verts[(i + 1) % v]
            let l = hypot(b.0 - a.0, b.1 - a.1)
            lengths.append(l)
            total += l
        }
        return { f in
            var target = f * total
            var i = 0
            while target > lengths[i] && i < v - 1 {
                target -= lengths[i]
                i += 1
            }
            let a = verts[i]
            let b = verts[(i + 1) % v]
            let ff = lengths[i] == 0 ? 0 : min(1, target / lengths[i])
            return (a.0 + (b.0 - a.0) * ff, a.1 + (b.1 - a.1) * ff)
        }
    }

    private static let trianglePath: (Double) -> (Double, Double) = polyPath([
        (0.0, -0.26), (0.24, 0.16), (-0.24, 0.16)
    ])
    private static let squarePath: (Double) -> (Double, Double) = polyPath([
        (0, -0.2), (0.2, -0.2), (0.2, 0.2), (-0.2, 0.2), (-0.2, -0.2)
    ])

    private struct Move {
        var axis: Int
        var lo: Double
        var hi: Double
        var ang: Double
    }

    private static func makeMoves(_ count: Int) -> [Move] {
        (0..<count).map { i in
            let axis = min(2, Int(floor(hashD(Double(i), 2.3) * 3)))
            let lo = -1.0 + 0.5 * min(3, floor(hashD(Double(i), 5.9) * 4))
            let dir: Double = hashD(Double(i), 7.7) < 0.5 ? 1 : -1
            return Move(axis: axis, lo: lo, hi: lo + 0.5, ang: dir * Double.pi / 2)
        }
    }

    private static func solveCycle(_ time: Double, _ count: Int, _ slotDur: Double, _ rest: Double) -> (amount: [Double], active: Int) {
        let cyc = 2 * Double(count) * slotDur + rest
        let tc = time.truncatingRemainder(dividingBy: cyc)
        var amount = Array(repeating: 0.0, count: count)
        var active = -1
        if tc < 2 * Double(count) * slotDur {
            let slot = Int(floor(tc / slotDur))
            let p = (tc - Double(slot) * slotDur) / slotDur
            let cl = min(1, p / 0.7)
            let ep = 1 - pow(1 - cl, 3)
            if slot < count {
                for i in 0..<slot { amount[i] = 1 }
                amount[slot] = ep
                active = slot
            } else {
                let u = 2 * count - 1 - slot
                for i in 0..<u { amount[i] = 1 }
                if u >= 0 && u < count {
                    amount[u] = 1 - ep
                    active = u
                }
            }
        }
        return (amount, active)
    }

    private static func applyMoves(
        _ pt3: (Double, Double, Double),
        _ moves: [Move],
        _ sc: (amount: [Double], active: Int)
    ) -> (Double, Double, Double, Bool) {
        var x = pt3.0, y = pt3.1, z = pt3.2
        var inActive = false
        for i in 0..<moves.count {
            guard sc.amount[i] > 0 else { continue }
            let mv = moves[i]
            let coord = mv.axis == 0 ? x : (mv.axis == 1 ? y : z)
            guard coord >= mv.lo && coord < mv.hi else { continue }
            if i == sc.active { inActive = true }
            let a = mv.ang * sc.amount[i]
            let ca = cos(a), sa = sin(a)
            if mv.axis == 0 {
                let y2 = y * ca - z * sa
                z = y * sa + z * ca
                y = y2
            } else if mv.axis == 1 {
                let x2 = x * ca + z * sa
                z = -x * sa + z * ca
                x = x2
            } else {
                let x2 = x * ca - y * sa
                y = x * sa + y * ca
                x = x2
            }
        }
        return (x, y, z, inActive)
    }
}
