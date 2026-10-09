import SwiftUI
import UIKit
import AVKit

// MARK: - Artwork palette

/// Nine colors sampled from a 3x3 grid of the artwork, tuned so white text
/// stays legible on top. Feeds the player's mesh background.
struct ArtworkPalette: Equatable {
    let id: String
    let colors: [Color]

    static func fallback(accent: Color) -> ArtworkPalette {
        let base = UIColor(accent)
        let deep = base.adjusted(saturation: 0.9, brightness: 0.28)
        let mid = base.adjusted(saturation: 0.75, brightness: 0.42)
        let lift = base.adjusted(saturation: 0.6, brightness: 0.55)
        let ui: [UIColor] = [lift, mid, deep,
                             mid, deep, mid,
                             deep, mid, lift]
        return ArtworkPalette(id: "fallback-\(base.description)", colors: ui.map(Color.init))
    }

    static func == (lhs: ArtworkPalette, rhs: ArtworkPalette) -> Bool { lhs.id == rhs.id }
}

enum ArtworkPaletteExtractor {
    nonisolated(unsafe) private static let cache: NSCache<NSString, PaletteBox> = {
        let cache = NSCache<NSString, PaletteBox>()
        cache.countLimit = 64
        return cache
    }()

    private final class PaletteBox: @unchecked Sendable {
        let palette: ArtworkPalette
        init(_ palette: ArtworkPalette) { self.palette = palette }
    }

    /// Off the main actor: draws the image into a 3x3 bitmap (the resampling
    /// averages each cell) and adjusts each cell for a dark, readable backdrop.
    static func palette(for key: String, image: UIImage) async -> ArtworkPalette? {
        if let cached = cache.object(forKey: key as NSString) { return cached.palette }

        let palette = await Task.detached(priority: .utility) { () -> ArtworkPalette? in
            guard let cgImage = image.cgImage else { return nil }
            let side = 3
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: side,
                    height: side,
                    bitsPerComponent: 8,
                    bytesPerRow: side * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.interpolationQuality = .medium
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
                return true
            }
            guard drawn else { return nil }

            var colors: [Color] = []
            colors.reserveCapacity(side * side)
            for index in 0..<(side * side) {
                let offset = index * 4
                let color = UIColor(
                    red: CGFloat(pixels[offset]) / 255,
                    green: CGFloat(pixels[offset + 1]) / 255,
                    blue: CGFloat(pixels[offset + 2]) / 255,
                    alpha: 1
                )
                colors.append(Color(color.tunedForBackdrop()))
            }
            return ArtworkPalette(id: key, colors: colors)
        }.value

        if let palette { cache.setObject(PaletteBox(palette), forKey: key as NSString) }
        return palette
    }
}

private extension UIColor {
    func adjusted(saturation: CGFloat, brightness: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return UIColor(hue: h, saturation: min(s, saturation), brightness: brightness, alpha: 1)
    }

    /// Keeps hue, nudges saturation up a little and clamps brightness into a
    /// band where white type keeps contrast and black art doesn't go flat.
    func tunedForBackdrop() -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let saturation = s < 0.08 ? s : min(1, s * 1.15 + 0.05)
        let brightness = min(0.62, max(0.2, b * 0.85))
        return UIColor(hue: h, saturation: saturation, brightness: brightness, alpha: 1)
    }
}

// MARK: - Ambient background

/// Slowly drifting mesh built from the artwork palette. Crossfades between
/// tracks and holds still when `isAnimating` is false or Reduce Motion is on.
struct PlayerAmbientBackground: View {
    let palette: ArtworkPalette
    let isAnimating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black
            mesh
                .id(palette.id)
                .transition(.opacity)
            // A soft vignette keeps the controls area readable on bright art.
            LinearGradient(
                colors: [.black.opacity(0.05), .black.opacity(0.15), .black.opacity(0.45)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .animation(.easeInOut(duration: 0.9), value: palette.id)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var mesh: some View {
        // The fastest point moves about a point per second, so 15 fps reads
        // the same as 60 and halves the redraws (glass above re-samples too).
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !isAnimating || reduceMotion)) { context in
            MeshGradient(
                width: 3,
                height: 3,
                points: Self.points(at: context.date.timeIntervalSinceReferenceDate),
                colors: palette.colors,
                smoothsColors: true
            )
        }
    }

    /// Corners stay pinned; edge midpoints slide along their edge and the
    /// center wanders, so the mesh never tears or exposes the backdrop.
    private static func points(at time: TimeInterval) -> [SIMD2<Float>] {
        let t = Float(time)
        let wobble: (Float, Float) -> Float = { speed, phase in 0.12 * sin(t * speed + phase) }
        return [
            [0, 0], [0.5 + wobble(0.31, 0), 0], [1, 0],
            [0, 0.5 + wobble(0.27, 1.3)], [0.5 + wobble(0.23, 2.1), 0.5 + wobble(0.19, 0.4)], [1, 0.5 + wobble(0.29, 2.7)],
            [0, 1], [0.5 + wobble(0.21, 3.3), 1], [1, 1]
        ]
    }
}

// MARK: - Liquid Glass (iOS 26+, material fallback)

extension View {
    /// Liquid Glass behind the view on iOS 26 and later; a thin material on
    /// earlier systems so the layout reads the same everywhere.
    @ViewBuilder
    func adaptiveGlass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Self.glass(interactive: interactive, tint: tint), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    @available(iOS 26.0, *)
    private static func glass(interactive: Bool, tint: Color?) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }

    /// The system glass button style on iOS 26 and later.
    @ViewBuilder
    func adaptiveGlassButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(PressableButtonStyle(pressedScale: 0.92))
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// Groups neighbouring glass shapes so they blend and morph into each other
/// on iOS 26 and later; a plain container before that.
struct AdaptiveGlassContainer<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Buttons

/// Shrinks and dims while pressed with a quick spring back.
struct PressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.86

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// The system route picker, which presents the AirPlay menu itself.
struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = .label
        picker.activeTintColor = .label
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Scrubber

/// Apple Music style scrubber: a thin capsule that thickens while dragged.
/// Drags are relative to where the finger lands; a tap seeks to the tap.
struct ElasticScrubber: View {
    let progress: Double
    let duration: TimeInterval
    let onSeek: (Double) async -> Void

    @State private var dragProgress: Double?
    @State private var dragStart: Double = 0

    private var isDragging: Bool { dragProgress != nil }
    private var shown: Double { dragProgress ?? progress }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                let height: CGFloat = isDragging ? 10 : 5

                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.22))
                    Capsule()
                        .fill(.primary.opacity(isDragging ? 1 : 0.85))
                        .frame(width: max(height, width * shown))
                }
                .frame(height: height)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragProgress == nil { dragStart = shown }
                            let next = dragStart + Double(value.translation.width / width)
                            dragProgress = min(1, max(0, next))
                        }
                        .onEnded { value in
                            let moved = abs(value.translation.width) > 3
                            let target = moved
                                ? (dragProgress ?? progress)
                                : min(1, max(0, Double(value.location.x / width)))
                            dragProgress = target
                            Task { @MainActor in
                                await onSeek(target)
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                    dragProgress = nil
                                }
                            }
                        }
                )
            }
            .frame(height: 22)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragging)
            .sensoryFeedback(.selection, trigger: isDragging) { _, new in new }

            HStack {
                Text(Self.format(shown * duration))
                Spacer()
                Text("-" + Self.format(max(0, duration - shown * duration)))
            }
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.primary.opacity(isDragging ? 0.9 : 0.55))
            .scaleEffect(isDragging ? 1.04 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragging)
        }
        .accessibilityElement()
        .accessibilityLabel(Text(Self.format(shown * duration)))
        .accessibilityValue(Text("\(Int(shown * 100))%"))
        .accessibilityAdjustableAction { direction in
            let step = duration > 0 ? 10 / duration : 0
            let target = min(1, max(0, shown + (direction == .increment ? step : -step)))
            Task { await onSeek(target) }
        }
    }

    static func format(_ time: TimeInterval) -> String {
        let safe = time.isFinite ? max(0, time) : 0
        let minutes = Int(safe) / 60
        let seconds = Int(safe) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Now playing marker

/// The track number, swapped for animated bars on the song that is playing,
/// as album track lists do in Apple Music. Observes only the engine's
/// low-frequency state, never the playback position.
struct TrackNumberOrNowPlaying: View {
    let trackStableId: String
    let number: Int
    let tint: Color
    @ObservedObject private var engine = PlayerEngine.shared

    var body: some View {
        let isCurrent = engine.currentTrack?.stableId == trackStableId
        ZStack(alignment: .leading) {
            if isCurrent {
                EqualizerBarsExact(
                    color: tint,
                    isActive: engine.isPlaying,
                    isLarge: true,
                    trackId: trackStableId
                )
                .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
            } else {
                Text("\(number)")
                    .font(.body.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: isCurrent)
    }
}

// MARK: - Artwork tile

/// Square artwork with the shared placeholder and hairline edge. Callers set
/// the frame; every cover in the redesigned screens goes through this.
struct ArtworkTile: View {
    let image: UIImage?
    var cornerRadius: CGFloat = 8
    var placeholderFont: Font = .body

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(placeholderFont)
                    .foregroundStyle(.tertiary)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

// MARK: - Pull to dismiss

/// Apple Music style pull-down-to-close: the page turns into a card that
/// follows the finger and uncovers what is behind it. The drag state lives
/// here, so a drag frame re-renders this wrapper only, not the content.
struct PullToDismiss<Content: View>: View {
    /// Off while the content scrolls vertically itself (lyrics).
    var isEnabled: Bool
    /// Checked when a drag starts, e.g. not while the artwork is being swiped.
    var canBegin: Bool
    /// True from the start of a pull until just after it ends. The page
    /// follows the finger, so a pull that began on a button is still "inside"
    /// it on release; the owner disables its controls while this is set.
    @Binding var isDragging: Bool
    let onDismiss: () -> Void
    @ViewBuilder var content: Content

    @State private var offset: CGFloat = 0

    var body: some View {
        content
            // A mask that ignores the safe area, unlike clipShape, which would
            // cut a full-bleed backdrop back to the safe-area rectangle.
            .mask {
                RoundedRectangle(cornerRadius: offset > 0 ? 44 : 0, style: .continuous)
                    .ignoresSafeArea()
            }
            .scaleEffect(1 - min(offset, 400) / 4000, anchor: .top)
            .offset(y: offset)
            .simultaneousGesture(pull, including: isEnabled ? .all : .subviews)
    }

    /// Only vertical, downward drags count, so horizontal gestures in the
    /// content (artwork swipe, scrubber) keep working.
    private var pull: some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .global)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard dy > 0, dy > abs(dx) * 1.2, canBegin || offset > 0 else { return }
                if !isDragging { isDragging = true }
                var transaction = Transaction()
                transaction.isContinuous = true
                withTransaction(transaction) { offset = dy }
            }
            .onEnded { value in
                // Re-enable the content after this touch's button actions ran.
                DispatchQueue.main.async { isDragging = false }
                guard offset > 0 else { return }
                if offset > 140 || value.predictedEndTranslation.height > 420 {
                    onDismiss()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        offset = 0
                    }
                }
            }
    }
}
