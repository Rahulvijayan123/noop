import MetalKit
import StrandDesign
import SwiftUI
import UIKit

// Native port of img-fx (MIT, Jakub Antalík): the "pixels-organic" preset, a churning pixel-mosaic
// shader (Chromium Flow) that dissolves cell by cell into the real content underneath. The GLSL
// fragment shader is translated to Metal; the DOM/canvas compositing of the reveal is folded into the
// same pass, using the library's own mask (proximity of the shader colour to palette slot 4).

// MARK: - Reveal timing

/// One definition of the dissolve, shared by the shader and by the chart build-up that runs alongside it.
enum ImageFXReveal {
    static let duration: Double = 5.0

    /// Eased dissolve progress, 0 to 1, after `elapsed` seconds.
    static func progress(elapsed: Double) -> Double {
        let p = min(1, max(0, elapsed / duration))
        return p * p * (3 - 2 * p)
    }

    /// How built the content underneath is at that progress. It trails the dissolve a little: it starts just
    /// after the first cells clear and finishes as the last of them go, so what is being drawn is still being
    /// drawn where the pixels are clearing.
    static func build(elapsed: Double) -> Double {
        min(1, max(0, (progress(elapsed: elapsed) - 0.1) / 0.85))
    }
}

// MARK: - Uniforms

/// Mirrors `FXUniforms` in the Metal source below. Field order and types must match exactly.
private struct ImageFXUniforms {
    var c1 = SIMD4<Float>(repeating: 0)
    var c2 = SIMD4<Float>(repeating: 0)
    var c3 = SIMD4<Float>(repeating: 0)
    var c4 = SIMD4<Float>(repeating: 0)
    var c5 = SIMD4<Float>(repeating: 0)
    var cardBg = SIMD4<Float>(repeating: 0)
    var resolution = SIMD2<Float>(1, 1)
    var dpr: Float = 1
    var time: Float = 0
    var speed: Float = 0.3
    var intensity: Float = 1
    var scale: Float = 1
    var direction: Float = 0
    var softness: Float = 0.76
    var distortion: Float = 0.3
    var complexity: Float = 0.2
    var shape: Float = 0.52
    var vignette: Float = 0.26
    var vigOpacity: Float = 1
    var blur: Float = 1
    var highlight: Float = 0.2
    var cellSize: Float = 0.22
    var gap: Float = 0.14
    var dotSize: Float = 0.8
    var dotSoftness: Float = 0.1
    var dotOpacity: Float = 0.68
    var hlScale: Float = 0.8
    var fillOpacity: Float = 0.44
    var edgeFade: Float = 24
    var fadeStr: Float = 1
    /// Eased reveal progress 0...1, or -1 while there is no reveal (the loading state).
    var reveal: Float = -1
    var revealSoftness: Float = 0.5
    /// 1 while this layer sits over content that must stay hidden until the reveal: an opaque card-coloured
    /// cover sits under the mosaic and dissolves with it.
    var backdrop: Float = 0
    /// 1 on a light card: the shader's brightness maths is mirrored (darker is stronger), so the mosaic is drawn as
    /// dark ink cells on the white card the way the dark theme draws pale cells on the dark one.
    var invert: Float = 0

    /// The bundled `pixels-organic` tuning for one theme. Palette slots that equal the preset's card
    /// colour are replaced by the real card surface, as img-fx does for its `cardBg` override.
    static func organic(dark: Bool, surface: SIMD4<Float>) -> ImageFXUniforms {
        func hex(_ value: UInt32) -> SIMD4<Float> {
            SIMD4(Float((value >> 16) & 0xFF) / 255, Float((value >> 8) & 0xFF) / 255, Float(value & 0xFF) / 255, 1)
        }
        var u = ImageFXUniforms()
        u.cardBg = surface
        if dark {
            u.c1 = surface; u.c2 = hex(0x4a4949); u.c3 = hex(0xb9b9b9); u.c4 = surface; u.c5 = hex(0xd8d8d8)
            u.direction = 0
            u.intensity = 1
            u.highlight = 0.2
            u.vignette = 0.26
            u.vigOpacity = 1
            u.fillOpacity = 0.44
            u.edgeFade = 24
        } else {
            // The dark tuning mirrored in greys down to black: the card colour is the empty cell, and the three ink
            // stops are to a white card what 4a4949 / b9b9b9 / d8d8d8 are to a dark one. Pale or tinted stops
            // left most cells (and their dissolve) hard to see on white.
            u.c1 = surface; u.c2 = hex(0x9a9a9a); u.c3 = hex(0x262626); u.c4 = surface; u.c5 = hex(0x000000)
            u.direction = 0
            u.intensity = 1
            u.highlight = 0.2
            u.vignette = 0.26
            u.vigOpacity = 1
            u.fillOpacity = 0.5
            u.dotOpacity = 0.92
            u.edgeFade = 24
            u.invert = 1
        }
        return u
    }
}

// MARK: - Renderer

/// Shared GPU state: one device, queue and compiled pipeline for every mosaic on screen.
private final class ImageFXRenderer {
    static let shared = ImageFXRenderer()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let vertex = library.makeFunction(name: "fx_vertex"),
              let fragment = library.makeFunction(name: "fx_fragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    // The shader's clock runs from a shared start, so the loading mosaic and the dissolve that follows it
    // (two different views) show the same flow instead of restarting. Kept small on purpose: a Float loses
    // its fractional seconds at phone-uptime magnitudes.
    private static let clockOrigin = Double.random(in: 0..<1000)
    private static let clockStart = CACurrentMediaTime()
    static func clock(scale: Double) -> Float {
        Float(clockOrigin + (CACurrentMediaTime() - clockStart) * scale)
    }

    private static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct FXUniforms {
        float4 c1, c2, c3, c4, c5, cardBg;
        float2 resolution;
        float dpr, time, speed, intensity, scale, direction;
        float softness, distortion, complexity, shape;
        float vignette, vigOpacity, blur, highlight;
        float cellSize, gap, dotSize, dotSoftness, dotOpacity, hlScale, fillOpacity, edgeFade, fadeStr;
        float reveal, revealSoftness, backdrop, invert;
    };

    struct VOut { float4 position [[position]]; };

    vertex VOut fx_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    constant float REF_DIM = 320.0;

    float2 gridCounts(float baseCount, constant FXUniforms& u) {
        float2 cssRes = u.resolution / max(u.dpr, 0.0001);
        return max(float2(2.0), floor(baseCount * cssRes / REF_DIM));
    }

    float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
    float2 mod289v2(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
    float3 permute(float3 x) { return mod289((x * 34.0 + 1.0) * x); }

    float snoise(float2 v) {
        const float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
        float2 i = floor(v + dot(v, C.yy));
        float2 x0 = v - i + dot(i, C.xx);
        float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
        float4 x12 = x0.xyxy + C.xxzz;
        x12.xy -= i1;
        i = mod289v2(i);
        float3 p = permute(permute(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
        float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), float3(0.0));
        m = m * m;
        m = m * m;
        float3 x_ = 2.0 * fract(p * C.www) - 1.0;
        float3 h = abs(x_) - 0.5;
        float3 ox = floor(x_ + 0.5);
        float3 a0 = x_ - ox;
        m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
        float3 g;
        g.x = a0.x * x0.x + h.x * x0.y;
        g.yz = a0.yz * x12.xz + h.yz * x12.yw;
        return 130.0 * dot(m, g);
    }

    float fbm(float2 p, float oct) {
        float val = 0.0, amp = 0.5;
        int n = int(oct);
        for (int i = 0; i < 4; i++) {
            if (i >= n) break;
            val += amp * snoise(p);
            p *= 2.0;
            amp *= 0.5;
        }
        return val;
    }

    float nfbm(float2 p, constant FXUniforms& u) { return fbm(p, 2.0 + u.complexity * 2.0); }

    float2 warp(float2 p, float t, constant FXUniforms& u) {
        float str = u.distortion * 2.0;
        return float2(nfbm(p + float2(t * 0.1, 0.0), u),
                      nfbm(p + float2(0.0, t * 0.12) + 5.0, u)) * str;
    }

    float3 softBlend(float a, float b, float c, constant FXUniforms& u) {
        a = clamp(a, 0.0, 1.0); a *= a;
        b = clamp(b, 0.0, 1.0); b *= b;
        c = clamp(c, 0.0, 1.0); c *= c;
        float d = clamp(a * 0.7 + c * 0.3, 0.0, 1.0); d *= d;
        float e = clamp(b * 0.5 + c * 0.5, 0.0, 1.0); e *= e;
        float total = a + b + c + d + e;
        float floorW = max(0.001 - total, 0.0);
        float3 fallback = (u.c1.xyz + u.c2.xyz + u.c3.xyz + u.c4.xyz + u.c5.xyz) * 0.2;
        return (u.c1.xyz * a + u.c2.xyz * b + u.c3.xyz * c + u.c4.xyz * d + u.c5.xyz * e + fallback * floorW)
            / (total + floorW);
    }

    // Effect 22, "Chromium Flow".
    float3 computeEffect(float2 uv, float aspect, float t, constant FXUniforms& u) {
        float dist = u.distortion, cpx = u.complexity, shp = u.shape;
        float2 p = (uv - 0.5) * u.scale;
        p.x *= aspect;
        p += float2(cos(u.direction), sin(u.direction)) * t * 0.15;

        float2 w = warp(p * 0.7, t * 0.5, u);
        float2 w2 = warp(p * 0.4 + w * 0.3, t * 0.3, u);
        float2 wp = p + w * (0.4 + dist * 0.6);
        float n1 = snoise(wp * (1.4 + cpx * 1.6) + t * 0.14);
        float n2 = snoise((wp + w2 * dist * 0.4) * (2.0 + cpx * 2.0) + float2(3.0, 7.0) - t * 0.1);
        float ridge1 = 1.0 - abs(n1);
        ridge1 = pow(ridge1, 5.0 + shp * 12.0);
        float ridge2 = 1.0 - abs(n2);
        ridge2 = pow(ridge2, 4.0 + shp * 10.0);
        float base = (n1 + n2) * 0.25 + 0.5;
        float a = (base * 0.6 + ridge1 * 1.2) * u.intensity;
        float b = ((1.0 - base) * 0.6 + ridge2 * 1.0) * u.intensity;
        float c = (ridge1 * 0.8 + ridge2 * 0.6) * u.intensity;
        return softBlend(a, b, c, u);
    }

    fragment float4 fx_fragment(VOut in [[stage_in]], constant FXUniforms& u [[buffer(0)]]) {
        // Metal's framebuffer origin is top-left; the GLSL original assumes bottom-left.
        float2 frag = float2(in.position.x, u.resolution.y - in.position.y);
        float2 uv = frag / u.resolution;
        float aspect = u.resolution.x / u.resolution.y;
        float t = u.time * u.speed;

        float2 gridSize = gridCounts(6.0 + u.cellSize * 74.0, u);
        float2 sampleUV = (floor(uv * gridSize) + float2(0.5)) / gridSize;

        float3 col;
        if (u.blur < 0.01) {
            col = computeEffect(sampleUV, aspect, t, u);
        } else {
            float r = u.blur * 0.02;
            col = computeEffect(sampleUV, aspect, t, u) * 0.4;
            col += computeEffect(sampleUV + float2(r, 0.0), aspect, t, u) * 0.15;
            col += computeEffect(sampleUV + float2(-r, 0.0), aspect, t, u) * 0.15;
            col += computeEffect(sampleUV + float2(0.0, r), aspect, t, u) * 0.15;
            col += computeEffect(sampleUV + float2(0.0, -r), aspect, t, u) * 0.15;
        }
        float3 baseCol = col;

        // Distance to the nearest edge in points, so the vignette and fade bands keep a constant width.
        float2 cssRes = u.resolution / max(u.dpr, 0.0001);
        float2 cssCoord = uv * cssRes;
        float edgeDistPx = min(min(cssCoord.x, cssRes.x - cssCoord.x), min(cssCoord.y, cssRes.y - cssCoord.y));
        float vigRangePx = 40.0 * (1.0 + u.vignette * 3.0);
        float vig = (edgeDistPx * edgeDistPx) / (vigRangePx * vigRangePx);
        vig = smoothstep(0.0, 1.0, vig);
        float vigFactor = mix(1.0, vig, u.vignette * u.vigOpacity);
        // Dark card: the edges sink toward black. Light card: they lift toward white, into the card.
        col = u.invert > 0.5 ? 1.0 - (1.0 - col) * vigFactor : col * vigFactor;

        float2 cellLocal = fract(uv * gridSize);

        float hlFactor = 0.0;
        if (u.highlight > 0.01 || u.hlScale > 0.01) {
            float2 cp2 = (sampleUV - 0.5) * u.scale;
            cp2.x *= aspect;
            float lw = sin(cp2.x * 3.0 + t * 1.5) * 0.5 + 0.5;
            lw *= sin(cp2.y * 2.5 - t * 1.1) * 0.5 + 0.5;
            lw += (snoise(cp2 * 2.0 + t * 0.6) * 0.5 + 0.5) * 0.3;
            hlFactor = clamp(lw, 0.0, 1.0);
            hlFactor *= hlFactor;
        }
        float scaleBoost = 1.0 + smoothstep(0.2, 0.8, hlFactor) * u.hlScale * 1.2;

        float mask = 1.0;
        float gapW = u.gap * 0.35 / scaleBoost;
        if (gapW > 0.003) {
            mask = step(gapW, cellLocal.x) * step(gapW, 1.0 - cellLocal.x)
                 * step(gapW, cellLocal.y) * step(gapW, 1.0 - cellLocal.y);
        }

        if (u.highlight > 0.01) {
            float hl = hlFactor * u.highlight;
            col = u.invert > 0.5
                ? 1.0 - (1.0 - col) * (1.0 + hl * 2.5) - float3(hl * hl * 0.3)
                : col * (1.0 + hl * 2.5) + float3(hl * hl * 0.3);
        }

        if (u.edgeFade > 0.5 && u.fadeStr > 0.005) {
            float ef = smoothstep(0.0, u.edgeFade, edgeDistPx);
            mask *= mix(1.0, ef, u.fadeStr);
        }

        float alpha = mix(u.fillOpacity, u.dotOpacity, mask);

        float bgLum = dot(u.cardBg.xyz, float3(0.299, 0.587, 0.114));
        float colLum = dot(baseCol, float3(0.299, 0.587, 0.114));
        alpha *= smoothstep(0.0, 0.33, abs(colLum - bgLum));

        // Reveal: each cell dissolves once the shader colour under it is close enough to palette slot 4
        // for the moving threshold, so the real content shows through in flowing patches.
        float e = 0.0;
        if (u.reveal >= 0.0) {
            float3 sc = u.invert > 0.5
                ? 1.0 - pow(max(1.0 - baseCol, float3(0.0)), float3(1.3))
                : pow(max(baseCol, float3(0.0)), float3(1.3));
            float3 d = sc - u.c4.xyz;
            float m = exp(-8.0 * dot(d, d));
            float thr = 1.0 - u.reveal * (1.0 + u.revealSoftness);
            e = clamp((m - thr) / u.revealSoftness, 0.0, 1.0);
            e = e * e * (3.0 - 2.0 * e);
            alpha *= (1.0 - e);
        }

        col = clamp(col, float3(0.0), float3(1.0));
        // The mosaic over an opaque card-coloured cover that dissolves with it, so content underneath
        // only shows where its cell has dissolved.
        float cover = u.backdrop > 0.5 ? (1.0 - e) : 0.0;
        float outA = alpha + cover * (1.0 - alpha);
        float3 outRGB = col * alpha + u.cardBg.xyz * cover * (1.0 - alpha);
        return float4(outRGB, outA);
    }
    """#
}

// MARK: - View

/// The mosaic as a transparent layer. With `revealing` false it churns indefinitely (the loading
/// state); flipping it true runs the dissolve once and calls `onRevealFinished`.
struct ImageFXMosaicView: View {
    var revealing: Bool = false
    var onFirstFrame: () -> Void = {}
    /// Called with the `CACurrentMediaTime()` at which the dissolve actually began.
    var onRevealStart: (CFTimeInterval) -> Void = { _ in }
    var onRevealFinished: () -> Void = {}

    /// False when Metal is unavailable; callers fall back to a static placeholder.
    static var isSupported: Bool { ImageFXRenderer.shared != nil }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dark = colorScheme == .dark
        var uniforms = ImageFXUniforms.organic(dark: dark, surface: Self.surface(dark: dark))
        uniforms.backdrop = revealing ? 1 : 0
        return ImageFXMetalView(
            uniforms: uniforms,
            // Reduce Motion slows the flow rather than removing the loader, as the thinking orb does.
            timeScale: reduceMotion ? 0.4 : 1,
            revealing: revealing,
            revealDuration: ImageFXReveal.duration,
            onFirstFrame: onFirstFrame,
            onRevealStart: onRevealStart,
            onRevealFinished: onRevealFinished
        )
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private static func surface(dark: Bool) -> SIMD4<Float> {
        let resolved = UIColor(StrandPalette.surfaceRaised)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4(Float(r), Float(g), Float(b), 1)
    }
}

private struct ImageFXMetalView: UIViewRepresentable {
    var uniforms: ImageFXUniforms
    var timeScale: Double
    var revealing: Bool
    var revealDuration: Double
    var onFirstFrame: () -> Void
    var onRevealStart: (CFTimeInterval) -> Void
    var onRevealFinished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: ImageFXRenderer.shared?.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        (view.layer as? CAMetalLayer)?.isOpaque = false
        view.contentScaleFactor = min(UIScreen.main.scale, 2)
        view.preferredFramesPerSecond = 30
        view.isUserInteractionEnabled = false
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let c = context.coordinator
        c.uniforms = uniforms
        c.timeScale = timeScale
        c.revealDuration = revealDuration
        c.onFirstFrame = onFirstFrame
        c.onRevealStart = onRevealStart
        c.onRevealFinished = onRevealFinished
        c.revealRequested = revealing
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var uniforms = ImageFXUniforms()
        var timeScale = 1.0
        var revealRequested = false
        var revealDuration = 4.5
        var onFirstFrame: () -> Void = {}
        var onRevealStart: (CFTimeInterval) -> Void = { _ in }
        var onRevealFinished: () -> Void = {}
        private var revealStart: CFTimeInterval?
        private var sentFirstFrame = false
        private var finished = false

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let renderer = ImageFXRenderer.shared,
                  let drawable = view.currentDrawable,
                  let pass = view.currentRenderPassDescriptor,
                  view.drawableSize.width > 1, view.drawableSize.height > 1,
                  let buffer = renderer.queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

            var u = uniforms
            u.resolution = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
            u.dpr = Float(view.contentScaleFactor)
            u.time = ImageFXRenderer.clock(scale: timeScale)
            var done = false
            // The dissolve starts on the first frame actually drawn, so none of it is spent off screen.
            if revealRequested, revealStart == nil, sentFirstFrame {
                let began = CACurrentMediaTime()
                revealStart = began
                DispatchQueue.main.async { [onRevealStart] in onRevealStart(began) }
            }
            if let start = revealStart {
                let elapsed = CACurrentMediaTime() - start
                u.reveal = Float(ImageFXReveal.progress(elapsed: elapsed))
                done = elapsed >= revealDuration
            } else {
                u.reveal = -1
            }

            encoder.setRenderPipelineState(renderer.pipeline)
            encoder.setFragmentBytes(&u, length: MemoryLayout<ImageFXUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            buffer.present(drawable)
            if !sentFirstFrame {
                sentFirstFrame = true
                buffer.addScheduledHandler { [weak self] _ in
                    DispatchQueue.main.async { self?.onFirstFrame() }
                }
            }
            buffer.commit()

            if done, !finished {
                finished = true
                DispatchQueue.main.async { [onRevealFinished] in onRevealFinished() }
            }
        }
    }
}

// MARK: - Reveal over real content

extension View {
    /// Keeps this view hidden behind the mosaic and dissolves the mosaic away over it, the first time it
    /// appears, when `active`. Nothing changes for views that were never a loading placeholder, or without
    /// Metal. `onFinished` fires once the mosaic is gone.
    func imageFXReveal(active: Bool, cornerRadius: CGFloat, onFinished: @escaping () -> Void = {}) -> some View {
        modifier(ImageFXRevealModifier(active: active, cornerRadius: cornerRadius, onFinished: onFinished))
    }
}

private struct ImageFXRevealModifier: ViewModifier {
    let cornerRadius: CGFloat
    let onFinished: () -> Void

    /// The cover is mounted from the first render so the content is never seen un-covered.
    @State private var covered: Bool
    /// Until the mosaic has drawn a frame, a plain card-coloured layer stands in for it.
    @State private var mosaicReady = false
    /// When the dissolve began; the content underneath builds up against the same clock.
    @State private var revealStart: CFTimeInterval?

    init(active: Bool, cornerRadius: CGFloat, onFinished: @escaping () -> Void) {
        self.cornerRadius = cornerRadius
        self.onFinished = onFinished
        _covered = State(initialValue: active && ImageFXMosaicView.isSupported)
    }

    /// How built the content is right now: untouched until the dissolve begins, whole once it is over.
    private func build() -> Double {
        guard covered else { return 1 }
        guard let start = revealStart else { return 0 }
        return ImageFXReveal.build(elapsed: CACurrentMediaTime() - start)
    }

    func body(content: Content) -> some View {
        // Paused (and so free) whenever there is nothing to build.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !covered)) { _ in
            content.environment(\.coachVizBuild, build())
        }
            .opacity(covered && !mosaicReady ? 0 : 1)
            .overlay {
                if covered {
                    ZStack {
                        if !mosaicReady { StrandPalette.surfaceRaised }
                        ImageFXMosaicView(
                            revealing: true,
                            onFirstFrame: { mosaicReady = true },
                            onRevealStart: { revealStart = $0 },
                            onRevealFinished: { finish() }
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .allowsHitTesting(false)
                }
            }
            // The cover is opaque and the content under it is hidden, so it must never depend on the Metal view
            // alone to go away: if that view stops delivering frames (it was detached, throttled or never got a
            // size), the card would stay a blank sheet until something happened to redraw it, which on a light card
            // reads as the screen going white. These deadlines end the cover whatever the GPU does.
            .task {
                guard covered else { return }
                try? await Task.sleep(nanoseconds: UInt64(Self.firstFrameDeadline * 1_000_000_000))
                guard covered, !Task.isCancelled else { return }
                if !mosaicReady { finish(); return }
                try? await Task.sleep(nanoseconds: UInt64((ImageFXReveal.duration + Self.finishGrace) * 1_000_000_000))
                guard covered, !Task.isCancelled else { return }
                finish()
            }
    }

    /// How long the mosaic has to draw its first frame before the content is shown plainly.
    private static let firstFrameDeadline: Double = 1.5
    /// Extra time past the dissolve's own length before the cover is removed regardless.
    private static let finishGrace: Double = 1.0

    private func finish() {
        guard covered else { return }
        covered = false
        onFinished()
    }
}
