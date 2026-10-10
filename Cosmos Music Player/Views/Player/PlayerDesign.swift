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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // One mesh whose colours animate to the new palette. Swapping in
            // a second mesh (`.id` + opacity transition) faded both over a
            // black backdrop, which dipped the screen dark on every track
            // change, and drew two meshes for the length of the fade.
            mesh
            // A soft vignette keeps the controls area readable on bright art.
            // In Dark Mode the whole wash sits much deeper, so the player
            // matches the rest of a dark interface instead of glowing.
            LinearGradient(
                colors: colorScheme == .dark
                    ? [.black.opacity(0.42), .black.opacity(0.5), .black.opacity(0.72)]
                    : [.black.opacity(0.0), .black.opacity(0.08), .black.opacity(0.35)],
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
    /// True while a finger is down; resets on its own if the drag is
    /// cancelled (e.g. it turned into a pull-down), which skips onEnded.
    @GestureState private var isTouching = false
    @State private var endedNormally = false
    /// Set once a touch has moved mainly vertically: that is a pull on the
    /// player, not a scrub, and must neither move nor seek the bar.
    @State private var isVerticalTouch = false

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
                        .updating($isTouching) { _, touching, _ in touching = true }
                        .onChanged { value in
                            endedNormally = false
                            let dx = abs(value.translation.width)
                            let dy = abs(value.translation.height)
                            if isVerticalTouch || (dy > 8 && dy > dx * 1.2) {
                                if !isVerticalTouch {
                                    isVerticalTouch = true
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragProgress = nil }
                                }
                                return
                            }
                            if dragProgress == nil { dragStart = shown }
                            let next = dragStart + Double(value.translation.width / width)
                            dragProgress = min(1, max(0, next))
                        }
                        .onEnded { value in
                            endedNormally = true
                            guard !isVerticalTouch else {
                                isVerticalTouch = false
                                return
                            }
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
            .onChange(of: isTouching) { _, touching in
                guard !touching, !endedNormally else { return }
                isVerticalTouch = false
                guard dragProgress != nil else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { dragProgress = nil }
            }
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
/// as album track lists do in Apple Music. Reads `NowPlayingStatus`, so a
/// pause re-renders only the row that is playing.
struct TrackNumberOrNowPlaying: View {
    let trackStableId: String
    let number: Int
    let tint: Color

    var body: some View {
        let status = NowPlayingStatus.shared
        let isCurrent = status.currentStableId == trackStableId
        ZStack(alignment: .leading) {
            if isCurrent {
                EqualizerBarsExact(
                    color: tint,
                    isActive: status.isPlaying,
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
    /// The grabber's tap: an ordinary, animated close.
    let onDismiss: () -> Void
    /// Called once a pull has carried the card off screen. It must close
    /// without a transition: a zoom back into the mini player replays from
    /// the presented view's frame, so a sliver of the card reappeared over
    /// the mini player's spot after the card had already gone.
    let onPulledAway: () -> Void
    @ViewBuilder var content: Content

    @State private var offset: CGFloat = 0
    /// Shown while the player is touched and for a moment after, then out of
    /// the way. Kept here, not in the player, so a touch re-renders only this.
    @State private var isGrabberVisible = true
    @State private var grabberHideTask: Task<Void, Never>?
    @State private var insets = EdgeInsets()
    @State private var height: CGFloat = 900

    /// 0 at rest, 1 once the card has travelled far enough to look like one.
    private var progress: CGFloat { min(max(offset, 0) / 120, 1) }

    var body: some View {
        content
            // Before the transforms below, so the grabber travels with the card.
            .overlay(alignment: .top) {
                grabber.padding(.top, -4)
            }
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            // Clipped to the whole screen, safe areas included: a mask laid
            // out in the safe area cut a strip off the top and bottom of the
            // full-bleed backdrop as soon as the card moved.
            .clipShape(ScreenCard(cornerRadius: 52 * progress, insets: insets))
            .scaleEffect(1 - 0.07 * progress, anchor: .top)
            .offset(y: offset)
            .gesture(
                DirectionalPan(
                    direction: .down,
                    isEnabled: isEnabled,
                    canBegin: canBegin,
                    onChanged: { translation in
                        revealGrabber()
                        var transaction = Transaction()
                        transaction.isContinuous = true
                        withTransaction(transaction) { offset = max(translation.y, 0) }
                    },
                    onEnded: { translation, velocity in
                        hideGrabber(after: 2.5)
                        finishPull(translation: translation.y, velocity: velocity.y)
                    }
                )
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in revealGrabber() }
                    .onEnded { _ in hideGrabber(after: 2.5) }
            )
            .onAppear { hideGrabber(after: 3) }
    }

    private func finishPull(translation: CGFloat, velocity: CGFloat) {
        guard offset > 0 else { return }
        if offset > 140 || velocity > 900 || translation + velocity * 0.25 > 420 {
            // Finish the move the finger started - slide the card off the
            // bottom - and only then close (see `onPulledAway`). Aimed a
            // third of a screen past the edge: a spring creeps through its
            // last few percent, which left the card's top edge lingering over
            // the mini player.
            let screenHeight = height + insets.top + insets.bottom
            withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
                offset = screenHeight * 1.35
            } completion: {
                onPulledAway()
            }
        } else {
            // Critically damped: any bounce carried the card past its resting
            // place, lifting it off the bottom edge so the library showed
            // through a strip below it for a few frames.
            withAnimation(.spring(response: 0.35, dampingFraction: 1)) {
                offset = 0
            }
        }
    }

    private var grabber: some View {
        Button(action: onDismiss) {
            Capsule()
                .fill(.white.opacity(0.4))
                .frame(width: 36, height: 5)
                .frame(width: 120, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isGrabberVisible ? 1 : 0)
        .allowsHitTesting(isGrabberVisible)
        .accessibilityLabel(Localized.close)
        .accessibilityHidden(!isGrabberVisible)
    }

    private func revealGrabber() {
        if !isGrabberVisible {
            withAnimation(.easeOut(duration: 0.2)) { isGrabberVisible = true }
        }
        // A fallback in case the touch is cancelled before it ends.
        hideGrabber(after: 4)
    }

    private func hideGrabber(after seconds: Double) {
        grabberHideTask?.cancel()
        grabberHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.45)) { isGrabberVisible = false }
        }
    }
}

/// A one-finger UIKit pan that only begins in its own direction. Once it
/// does, UIKit cancels the touch for everything underneath - the way a
/// scroll view does - so a pull that starts on a button no longer fires it
/// on release, and one that starts on the scrubber no longer seeks.
///
/// The player's pull-down and the artwork's sideways swipe both use it, so
/// they never compete for a touch: a SwiftUI DragGesture claims a drag in
/// any direction, and a child's claim beats its ancestor's, so a pull that
/// started on the artwork used to nudge the artwork instead of closing the
/// player.
struct DirectionalPan: UIGestureRecognizerRepresentable {
    enum Direction {
        case down, horizontal
    }

    var direction: Direction
    var isEnabled = true
    var canBegin = true
    var onChanged: (_ translation: CGPoint) -> Void
    var onEnded: (_ translation: CGPoint, _ velocity: CGPoint) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(direction: direction)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
        context.coordinator.canBegin = canBegin
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: nil)
        switch recognizer.state {
        case .began, .changed:
            onChanged(translation)
        case .ended:
            onEnded(translation, recognizer.velocity(in: nil))
        case .cancelled, .failed:
            onEnded(translation, .zero)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let direction: Direction
        var canBegin = true

        init(direction: Direction) {
            self.direction = direction
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard canBegin, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: nil)
            let translation = pan.translation(in: nil)
            let dy = abs(velocity.y) > 1 ? velocity.y : translation.y
            let dx = abs(velocity.x) > 1 ? velocity.x : translation.x
            switch direction {
            case .down: return dy > 0 && dy > abs(dx) * 1.2
            case .horizontal: return abs(dx) > abs(dy) * 1.2
            }
        }
    }
}

/// A rounded rectangle covering the view and its safe areas.
private struct ScreenCard: Shape {
    var cornerRadius: CGFloat
    var insets: EdgeInsets

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let full = CGRect(
            x: rect.minX - insets.leading,
            y: rect.minY - insets.top,
            width: rect.width + insets.leading + insets.trailing,
            height: rect.height + insets.top + insets.bottom
        )
        return Path(roundedRect: full, cornerRadius: cornerRadius, style: .continuous)
    }
}


// MARK: - Play/pause glyph

/// Play and pause drawn together, the hidden one faded and shrunk, so a toggle
/// only animates opacity and scale. Swapping the symbol instead
/// (`.contentTransition(.symbolEffect(.replace))`) built the incoming glyph's
/// render surface on the tap - a GPU pipeline compile the first time - and
/// any main-thread work landing in that window froze the morph between the
/// two glyphs, so the button blinked out.
struct PlayPauseGlyph: View {
    let isPlaying: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
            glyph("pause.fill", isShown: isPlaying)
            glyph("play.fill", isShown: !isPlaying)
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isPlaying)
    }

    private func glyph(_ systemName: String, isShown: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .regular))
            .scaleEffect(isShown ? 1 : 0.4)
            .opacity(isShown ? 1 : 0)
    }
}

// MARK: - Responsive transport

/// Play/pause that answers the finger first. Starting the engine can take a
/// couple of frames (audio session, scheduling), and the button used to wait
/// for it: the haptic, the glyph and the artwork all changed only once
/// `isPlaying` flipped. Now they change on the tap, and the engine starts a
/// frame later, after that change is on screen.
@MainActor
enum ResponsiveTransport {
    private static let haptic: UIImpactFeedbackGenerator = {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        return generator
    }()

    /// Creates and spins up the haptic engine ahead of the first tap; doing
    /// it on the tap itself cost the first pause a dropped frame or several.
    static func prepare() {
        haptic.prepare()
    }

    /// - Parameter pending: the caller's optimistic state; shown in place of
    ///   `displaysPlaying` until the engine has caught up.
    static func toggle(_ engine: PlayerEngine, pending: Binding<Bool?>) {
        let target = !(pending.wrappedValue ?? engine.displaysPlaying)
        haptic.impactOccurred()
        haptic.prepare()
        pending.wrappedValue = target
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) {
            if target { engine.play() } else { engine.pause() }
            // Hold the shown state until the engine agrees (a resume after a
            // long pause, or one waiting on a load, lands later); letting go
            // early flipped the glyph back and forth.
            Task { @MainActor in
                for _ in 0..<30 where engine.displaysPlaying != target {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                pending.wrappedValue = nil
            }
        }
    }
}
