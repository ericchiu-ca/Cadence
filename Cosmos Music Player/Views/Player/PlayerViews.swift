import SwiftUI
import AVKit

struct EqualizerBarsExact: View {
    let color: Color
    let isActive: Bool
    let isLarge: Bool
    let trackId: String?

    private var minH: CGFloat { isLarge ? 2 : 1 }
    private var targetH: [CGFloat] { isLarge ? [4, 12, 8, 16] : [3, 8, 6, 10] }
    private let durations: [Double] = [0.6, 0.8, 0.4, 0.7]

    @State private var kick = false
    @Environment(\.scenePhase) private var scenePhase

    private var restartKey: String { "\(isActive)-\(trackId ?? "")" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(color)
                    .frame(width: isLarge ? 2 : 1.5)
                    .frame(height: isActive && kick ? targetH[i] : minH)
                    .animation(
                        isActive
                        ? .easeInOut(duration: durations[i]).repeatForever(autoreverses: true)
                        : .easeInOut(duration: 0.2),
                        value: kick
                    )
            }
        }
        .frame(width: isLarge ? 12 : 10, height: isLarge ? 20 : 12)
        .id(restartKey)                 // force view identity reset on key change
        .task(id: restartKey) { restart() } // runs on mount and when key changes
        .onChange(of: scenePhase) { p in
            if p == .active { restart() }   // recover after app foregrounding
        }
    }

    private func restart() {
        kick = false
        DispatchQueue.main.async {
            if isActive { kick = true }     // start a fresh repeatForever cycle
        }
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
import GRDB

private enum ArtworkSwipeDirection: Equatable {
    case previous
    case next

    var offsetSign: CGFloat {
        switch self {
        case .previous: return 1
        case .next: return -1
        }
    }
}

/// What the full player shows above its controls.
enum PlayerPanel {
    case artwork, lyrics, queue
}

struct PlayerView: View {
    @ObservedObject private var playerEngine = PlayerEngine.shared
    @ObservedObject private var artworkManager = ArtworkManager.shared
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var palette: ArtworkPalette?
    @State private var trackContext = PlayerTrackContext()
    @State private var skipForwardTrigger = 0
    @State private var skipBackwardTrigger = 0
    /// Shown in place of `isPlaying` from the tap until the engine catches up.
    @State private var pendingPlaying: Bool?
    @State private var currentArtwork: UIImage?
    @State private var nextArtwork: UIImage?
    @State private var previousArtwork: UIImage?
    @State private var dragOffset: CGFloat = 0
    @State private var isAnimating = false
    @State private var isFavorite = false
    @State private var showPlaylistDialog = false
    /// What fills the space above the controls. Lyrics and the queue share
    /// the compact header, as in Apple Music, so the queue sits within thumb
    /// reach above the controls instead of opening as a sheet led by a Done
    /// button in the top corner.
    @State private var panel: PlayerPanel = .artwork
    /// Bumped to close the card with its slide; see `PlayerCard`.
    @State private var closeRequest = 0
    /// Where the two layouts want the artwork, in the content's coordinates.
    /// Kept in state so the toggle animates between known frames.
    @State private var largeArtworkSlot: CGRect = .zero
    @State private var compactArtworkSlot = CGRect(x: 0, y: 12, width: 64, height: 64)
    /// 0 = full-size artwork, 1 = compact header. The only value animated by
    /// a panel change; the artwork interpolates between the slots from it.
    @State private var compactProgress: CGFloat = 0
    @State private var currentLyrics: Lyrics? = nil
    @State private var isLoadingLyrics = false
    @State private var settings = DeleteSettings.load()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appColorScheme) private var appColorScheme
    /// Ends the presentation without a transition; see `PlayerCard.onSlidAway`.
    private let closeWithoutTransition: () -> Void

    init(closeWithoutTransition: @escaping () -> Void) {
        self.closeWithoutTransition = closeWithoutTransition
        // The card is on screen from its first frame, so start from what the
        // mini player has already warmed: waiting for the async loads showed
        // a placeholder note and the accent-coloured fallback backdrop, which
        // then faded to the artwork's colours on every open.
        if let stableId = PlayerEngine.shared.currentTrack?.stableId {
            _palette = State(initialValue: ArtworkPaletteExtractor.cachedPalette(for: stableId))
            _currentArtwork = State(initialValue: ArtworkManager.shared.cachedArtwork(for: stableId))
        }
    }

    private var showLyrics: Bool { panel == .lyrics }
    /// Lyrics or the queue: the artwork sits in the header.
    private var isCompact: Bool { panel != .artwork }
    /// Landscape-shaped and roomy: iPad in landscape, a foldable's inner
    /// display turned sideways. Artwork on the left, everything else on the
    /// right, and lyrics or the queue open in the right column while the
    /// artwork stays where it is.
    @State private var isWide = false
    /// Whether the artwork sits in the compact header. Never when wide.
    private var artworkIsCompact: Bool { isCompact && !isWide }

    /// Slides the card away, like the end of a pull.
    private func close() {
        closeRequest += 1
    }
    
    var body: some View {
        PlayerCard(
            isEnabled: !isCompact,
            canBegin: dragOffset == 0,
            closeRequest: closeRequest,
            onSlidAway: closeWithoutTransition
        ) {
            ZStack {
                PlayerAmbientBackground(
                    palette: palette ?? .fallback(accent: settings.backgroundColorChoice.color),
                    // Still while covered by a sheet or in Low Power Mode.
                    isAnimating: playerEngine.displaysPlaying
                        && !showPlaylistDialog
                        && !ProcessInfo.processInfo.isLowPowerModeEnabled
                )
                mainContent
            }
        }
        // Cap Dynamic Type so large accessibility sizes don't overflow the player layout
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityAction(.escape) { close() }
        .onAppear { ResponsiveTransport.prepare() }

        .task(id: playerEngine.currentTrack?.stableId) {
            await refreshTrackContext()
        }
    }

    private var mainContent: some View {
        contentView
            // The backdrop is always a dark wash of the artwork colours, so
            // the player's own content renders with the dark appearance.
            // Sheets attach below and keep the app's appearance.
            .environment(\.colorScheme, .dark)
            .padding(.horizontal, isWide ? 48 : 20)
            .padding(.bottom, 8)
            // One centred column on wide screens (iPad, a foldable's inner
            // display): controls stretched edge to edge read as a mistake.
            .frame(maxWidth: isWide ? Self.maxWideWidth : Self.maxColumnWidth)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.size.width > proxy.size.height * 1.15 && proxy.size.width >= 700
            } action: { wide in
                isWide = wide
            }
            .onChange(of: playerEngine.currentTrack) { _, _ in
                guard !isAnimating else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragOffset = 0
                }
                Task {
                    await loadAllArtworks()
                }
            }
            .onAppear {
                Task {
                    await loadAllArtworks()
                    checkFavoriteStatus()
                }
            }
            .onChange(of: playerEngine.currentTrack) { _, newTrack in
                checkFavoriteStatus()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
                settings = DeleteSettings.load()
            }
            .onReceive(NotificationCenter.default.publisher(for: .cosmosSettingsDidChange)) { _ in
                settings = DeleteSettings.load()
            }
            .sheet(isPresented: $showPlaylistDialog) {
                playlistSheet
                    .preferredColorScheme(appColorScheme)
            }
            .onChange(of: playerEngine.currentTrack) { oldValue, newValue in
                // Clear current lyrics
                currentLyrics = nil

                // If lyrics are showing, load lyrics for the new track
                if showLyrics {
                    loadLyrics()
                } else {
                    isLoadingLyrics = false
                }
            }
    }

    private var contentView: some View {
        Group {
            if isWide {
                wideLayout
            } else {
                tallLayout
            }
        }
        .coordinateSpace(.named(Self.contentSpace))
        // One artwork for both layouts. Each layout only leaves a slot and
        // records its frame; this single view moves between the two frames
        // inside the toggle's own animation, so it is one continuous flight
        // instead of two views cross-matching while their containers change.
        .overlay(alignment: .topLeading) {
            if playerEngine.currentTrack != nil {
                floatingArtwork
                    .allowsHitTesting(false)
            }
        }
    }

    /// Two columns: the artwork fills the left, the right holds the title
    /// and controls, centred, or - with lyrics or the queue open - the
    /// panel between the title and the controls.
    private var wideLayout: some View {
        HStack(spacing: 56) {
            if let currentTrack = playerEngine.currentTrack {
                artworkSection(wide: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 0) {
                    if isCompact {
                        titleAndArtistSection(track: currentTrack)
                            .padding(.top, 28)
                        compactPanel
                            .frame(maxHeight: .infinity)
                            .padding(.top, 8)
                            .transition(.opacity)
                    } else {
                        Spacer(minLength: 20)
                        titleAndArtistSection(track: currentTrack)
                    }
                    progressBarSection
                        .padding(.top, 18)
                    controlsSection
                        .padding(.top, 6)
                    if !isCompact {
                        Spacer(minLength: 20)
                    }
                }
                .frame(maxWidth: 460)
            } else {
                Spacer()
                emptyStateView
                Spacer()
            }
        }
    }

    private var tallLayout: some View {
        VStack(spacing: 0) {
            if let currentTrack = playerEngine.currentTrack {
                if isCompact {
                    // Apple Music's lyrics and queue modes: the artwork shrinks
                    // into the header, the panel takes the stage, the controls
                    // stay put.
                    compactHeader(track: currentTrack)
                        .padding(.top, 12)
                        .transition(.opacity)
                    compactPanel
                        .frame(maxHeight: .infinity)
                        .padding(.top, 4)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 40)),
                            removal: .opacity
                        ))
                } else {
                    Spacer(minLength: 20)
                    artworkSection(wide: false)
                        // Leaves at once: only the floating artwork moves.
                        .transition(.identity)
                    Spacer(minLength: 16)
                    titleAndArtistSection(track: currentTrack)
                        .transition(.opacity)
                }
                progressBarSection
                    .padding(.top, 18)
                controlsSection
                    .padding(.top, 6)
            } else {
                Spacer()
                emptyStateView
                Spacer()
            }
        }
    }

    private static let contentSpace = "playerContent"
    private static let maxColumnWidth: CGFloat = 640
    private static let maxWideWidth: CGFloat = 1180
    private static let maxArtworkSize: CGFloat = 600

    /// Apple Music style: the artwork sits back while paused. The swipe's
    /// neighbours share it, so the incoming cover lands at the size the
    /// floating artwork then takes over at, instead of shrinking after.
    private var artworkRestingScale: CGFloat {
        (artworkIsCompact || showsPlaying) ? 1 : 0.84
    }

    private var floatingArtwork: some View {
        let pageDistance = largeArtworkSlot.width + 24
        let swipeProgress = artworkIsCompact ? 0 : min(abs(dragOffset) / max(pageDistance, 1), 1)
        let isLarge = !artworkIsCompact && showsPlaying

        return FlyingArtwork(
            image: currentArtwork,
            from: largeArtworkSlot,
            to: compactArtworkSlot,
            progress: isWide ? 0 : compactProgress,
            scale: artworkRestingScale * (1 - (0.04 * swipeProgress)),
            shadowStrength: isLarge ? 1 : 0.35
        )
        .animation(
            reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.72),
            value: showsPlaying
        )
        .offset(x: artworkIsCompact ? 0 : dragOffset)
        .opacity(1 - Double(swipeProgress) * 0.35)
    }


    private var playlistSheet: some View {
        Group {
            if let currentTrack = playerEngine.currentTrack {
                PlaylistSelectionView(track: currentTrack)
                    .accentColor(settings.backgroundColorChoice.color)
            }
        }
    }

    @ViewBuilder
    private var compactPanel: some View {
        switch panel {
        case .queue:
            QueueManagementView()
                .transition(.opacity)
        case .lyrics, .artwork:
            lyricsPanel
                .transition(.opacity)
        }
    }

    private var lyricsPanel: some View {
        LiveLyrics(
            lyrics: currentLyrics,
            isLoading: isLoadingLyrics,
            isPlaying: playerEngine.isPlaying,
            onRetry: { loadLyrics(forceRefresh: true) },
            track: playerEngine.currentTrack,
            onSelectAlternative: { id in applyLyricsAlternative(id) }
        )
        // Lyrics scroll vertically, so here the pull-down-to-close gesture
        // would fight them; the grabber and the header still close it.
        .padding(.horizontal, -4)
    }

    /// The header lyrics and queue modes shrink into: small artwork that
    /// morphs from the full-size one, title and artist, and the same glass
    /// actions.
    private func compactHeader(track: Track) -> some View {
        HStack(spacing: 12) {
            // Slot for the floating artwork; tapping it brings the artwork back.
            Color.clear
                .frame(width: 64, height: 64)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.contentSpace)) } action: {
                    compactArtworkSlot = $0
                }
                .contentShape(Rectangle())
                .onTapGesture { show(.artwork) }
                .accessibilityElement()
                .accessibilityLabel(Localized.lyrics)
                .accessibilityAddTraits(.isButton)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.headline)
                    .lineLimit(1)
                if let artistName = displayArtistName {
                    Text(artistName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .id(track.stableId)
            .transition(.blurReplace)
            .frame(maxWidth: .infinity, alignment: .leading)

            trackActions
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: track.stableId)
    }

    private var showsPlaying: Bool { pendingPlaying ?? playerEngine.displaysPlaying }

    private var panelAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.55, dampingFraction: 0.86)
    }

    /// The panel's button: opens it, or goes back to the artwork if it is
    /// already open.
    private func toggle(_ target: PlayerPanel) {
        show(panel == target ? .artwork : target)
    }

    private func show(_ target: PlayerPanel) {
        withAnimation(panelAnimation) {
            panel = target
            compactProgress = target == .artwork ? 0 : 1
        }
        if target == .lyrics, currentLyrics == nil, !isLoadingLyrics {
            loadLyrics()
        }
    }

    // MARK: - Artwork Section

    private func artworkSection(wide: Bool) -> some View {
        GeometryReader { geometry in
            let artworkSize = min(geometry.size.width, geometry.size.height, Self.maxArtworkSize)
            let gestureWidth = max(geometry.size.width, 1)
            let pageDistance = artworkSize + 24
            let signedProgress = max(-1, min(1, dragOffset / pageDistance))
            let canNavigate = playerEngine.playbackQueue.count > 1

            ZStack {
                // Neighbours stay invisible at rest - peeking slivers at the
                // screen edges read as a layout glitch - and fade in with the
                // swipe that brings them on screen.
                if canNavigate {
                    artworkTile(artwork: previousArtwork, size: artworkSize)
                        .offset(x: dragOffset - pageDistance)
                        .scaleEffect(artworkRestingScale * (0.92 + (0.08 * max(0, signedProgress))))
                        .opacity(Double(max(0, signedProgress)))
                        .zIndex(0)
                }

                // Slot for the floating artwork, which is drawn above the
                // whole player; the swipe still moves it through dragOffset.
                Color.clear
                    .frame(width: artworkSize, height: artworkSize)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.contentSpace)) } action: {
                        // Only from the layout on screen: the one being
                        // swapped out reports once more while it fades, and
                        // that stale frame would win.
                        if wide == isWide { largeArtworkSlot = $0 }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        close()
                    }
                    .zIndex(1)

                if canNavigate {
                    artworkTile(artwork: nextArtwork, size: artworkSize)
                        .offset(x: dragOffset + pageDistance)
                        .scaleEffect(artworkRestingScale * (0.92 + (0.08 * max(0, -signedProgress))))
                        .opacity(Double(max(0, -signedProgress)))
                        .zIndex(0)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                artworkSwipe(
                    gestureWidth: gestureWidth,
                    pageDistance: pageDistance
                )
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: Self.maxArtworkSize)
    }

    private func artworkTile(artwork: UIImage?, size: CGFloat, cornerRadius: CGFloat = 18) -> some View {
        ArtworkTile(image: artwork, cornerRadius: cornerRadius, placeholderFont: .system(size: min(80, size * 0.2)))
            .frame(width: size, height: size)
    }

    /// Horizontal only (see `DirectionalPan`), so a downward drag that starts
    /// on the artwork closes the player instead.
    private func artworkSwipe(gestureWidth: CGFloat, pageDistance: CGFloat) -> DirectionalPan {
        DirectionalPan(
            direction: .horizontal,
            canBegin: !isAnimating,
            onChanged: { translation in
                guard !isAnimating else { return }

                let canNavigate = playerEngine.playbackQueue.count > 1
                let proposedOffset = canNavigate
                    ? translation.x
                    : translation.x * 0.16
                let limit = pageDistance
                var transaction = Transaction()
                transaction.isContinuous = true
                withTransaction(transaction) {
                    dragOffset = max(-limit, min(limit, proposedOffset))
                }
            },
            onEnded: { translationPoint, velocity in
                guard !isAnimating else { return }
                guard playerEngine.playbackQueue.count > 1 else {
                    resetArtworkDrag()
                    return
                }

                let translation = translationPoint.x
                let projectedTranslation = translation + velocity.x * 0.25
                let distanceThreshold = gestureWidth * 0.22
                let projectionThreshold = gestureWidth * 0.34
                let shouldCommit = abs(translation) > distanceThreshold ||
                    abs(projectedTranslation) > projectionThreshold

                guard shouldCommit else {
                    resetArtworkDrag()
                    return
                }

                let directionValue = abs(projectedTranslation) > abs(translation)
                    ? projectedTranslation
                    : translation

                if directionValue > 0 {
                    completeArtworkSwipe(.previous, pageDistance: pageDistance)
                } else {
                    completeArtworkSwipe(.next, pageDistance: pageDistance)
                }
            }
        )
    }

    private func resetArtworkDrag() {
        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.14)
            : .spring(response: 0.36, dampingFraction: 0.82)
        withAnimation(animation) {
            dragOffset = 0
        }
    }

    private func completeArtworkSwipe(_ direction: ArtworkSwipeDirection, pageDistance: CGFloat) {
        // "Previous" restarts the current track after three seconds. Keep the
        // artwork honest in that case instead of briefly showing another song.
        if direction == .previous && playerEngine.playbackTime > 3 {
            resetArtworkDrag()
            Task {
                await playerEngine.previousTrack()
            }
            return
        }

        isAnimating = true
        let oldTrackId = playerEngine.currentTrack?.stableId
        let outgoingArtwork = currentArtwork
        let incomingArtwork = direction == .next ? nextArtwork : previousArtwork
        // Exactly one page: the adjacent card lands at x == 0. Any overrun
        // here causes a visible jump when the buffers are normalized.
        let targetOffset = direction.offsetSign * pageDistance

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let commitAnimation: Animation = reduceMotion
            ? .easeOut(duration: 0.14)
            : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)
        withAnimation(commitAnimation) {
            dragOffset = targetOffset
        }

        Task { @MainActor in
            let animationDelay: UInt64 = reduceMotion ? 140_000_000 : 240_000_000
            try? await Task.sleep(nanoseconds: animationDelay)

            switch direction {
            case .previous:
                await playerEngine.previousTrack()
            case .next:
                await playerEngine.nextTrack()
            }

            guard playerEngine.currentTrack?.stableId != oldTrackId else {
                isAnimating = false
                resetArtworkDrag()
                return
            }

            // The incoming card is already centered. Replace the artwork
            // buffers and reset coordinates without animation, so there is no
            // jump or flash while the engine finishes changing tracks.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                currentArtwork = incomingArtwork
                switch direction {
                case .previous:
                    nextArtwork = outgoingArtwork
                case .next:
                    previousArtwork = outgoingArtwork
                }
                dragOffset = 0
            }

            if currentArtwork == nil {
                await loadCurrentArtwork()
            }

            isAnimating = false
            await loadNextArtwork()
            await loadPreviousArtwork()
        }
    }

    // MARK: - Title and Artist Section

    private func titleAndArtistSection(track: Track) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                titleButton(track: track)
                artistButton(track: track)
            }
            .id(track.stableId)
            .transition(.blurReplace)
            .frame(maxWidth: .infinity, alignment: .leading)

            trackActions
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: track.stableId)
    }

    private func titleButton(track: Track) -> some View {
        Button {
            guard let album = trackContext.album else { return }
            let userInfo = ["album": album, "allTracks": libraryTracks()] as [String: Any]
            NotificationCenter.default.post(name: NSNotification.Name("NavigateToAlbumFromPlayer"), object: nil, userInfo: userInfo)
        } label: {
            Text(track.title)
                .font(.title2.weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .disabled(trackContext.album == nil)
    }

    @ViewBuilder
    private func artistButton(track: Track) -> some View {
        if let artistName = displayArtistName {
            Button {
                guard let artist = trackContext.artist else { return }
                let userInfo = ["artist": artist, "allTracks": libraryTracks()] as [String: Any]
                NotificationCenter.default.post(name: NSNotification.Name("NavigateToArtistFromPlayer"), object: nil, userInfo: userInfo)
            } label: {
                Text(artistName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .disabled(trackContext.artist == nil)
        }
    }

    /// Like and add-to-playlist, as one glass group; shared by the full and
    /// the lyrics-mode header.
    private var trackActions: some View {
        AdaptiveGlassContainer(spacing: 10) {
            HStack(spacing: 10) {
                likeButton
                addToPlaylistButton
            }
        }
    }

    private var displayArtistName: String? {
        trackContext.artistDisplayName ?? trackContext.artist?.name
    }

    private var likeButton: some View {
        Button {
            toggleFavorite()
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isFavorite ? Color.pink : Color.primary)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: isFavorite)
                .frame(width: 40, height: 40)
                .adaptiveGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: isFavorite)
        .accessibilityLabel(isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs)
    }

    private var addToPlaylistButton: some View {
        Button {
            showPlaylistDialog = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 40)
                .adaptiveGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Localized.addToPlaylist)
    }

    // MARK: - Progress Bar Section

    private var progressBarSection: some View {
        PlayerProgressSection(
            duration: playerEngine.duration,
            onSeek: { newTime in
                await playerEngine.seek(to: newTime)
            }
        )
    }

    // MARK: - Controls Section

    private var controlsSection: some View {
        VStack(spacing: 0) {
            playbackControlsView
                .frame(maxHeight: 120)
            additionalControlsView
        }
    }

    /// Bare glyphs, no container - the Apple Music layout. Previous and next
    /// bounce on tap; play and pause cross-fade (see `PlayPauseGlyph`).
    private var playbackControlsView: some View {
        HStack(spacing: 0) {
            Button {
                skipBackwardTrigger += 1
                Task { await playerEngine.previousTrack() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 32, weight: .regular))
                    .symbolEffect(.bounce.byLayer, options: .speed(1.6), value: skipBackwardTrigger)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Localized.previousTrack)

            Button {
                ResponsiveTransport.toggle(playerEngine, pending: $pendingPlaying)
            } label: {
                PlayPauseGlyph(isPlaying: showsPlaying, size: 50)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(showsPlaying ? Localized.pause : Localized.play)

            Button {
                skipForwardTrigger += 1
                Task { await playerEngine.nextTrack() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 32, weight: .regular))
                    .symbolEffect(.bounce.byLayer, options: .speed(1.6), value: skipForwardTrigger)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Localized.nextTrack)
        }
        .buttonStyle(PressableButtonStyle())
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .sensoryFeedback(.impact(weight: .light), trigger: skipForwardTrigger)
        .sensoryFeedback(.impact(weight: .light), trigger: skipBackwardTrigger)
    }

    /// Secondary actions in one quiet row. A mode that is switched on gets a
    /// glass disc, so state reads at a glance without extra colour.
    private var additionalControlsView: some View {
        AdaptiveGlassContainer(spacing: 8) {
            HStack(spacing: 0) {
                toolButton(
                    systemName: "shuffle",
                    isActive: playerEngine.isShuffled,
                    label: Localized.shuffle
                ) {
                    playerEngine.toggleShuffle()
                }

                if settings.showLyricsButton {
                    lyricsButton
                }

                AirPlayRouteButton()
                    .frame(width: 44, height: 44)
                    .frame(maxWidth: .infinity)

                if settings.showSleepTimerButton {
                    sleepTimerButton
                }

                toolButton(systemName: "list.bullet", isActive: panel == .queue, label: Localized.playingQueue) {
                    toggle(.queue)
                }

                toolButton(
                    systemName: playerEngine.isLoopingSong ? "repeat.1" : "repeat",
                    isActive: playerEngine.isLoopingSong || playerEngine.isRepeating,
                    label: Localized.repeatMode
                ) {
                    playerEngine.cycleLoopMode()
                }
            }
        }
        .sensoryFeedback(.selection, trigger: playerEngine.isShuffled)
        .sensoryFeedback(.selection, trigger: playerEngine.isRepeating)
        .sensoryFeedback(.selection, trigger: playerEngine.isLoopingSong)
    }

    private func toolButton(
        systemName: String,
        isActive: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            toolGlyph(systemName: systemName, isActive: isActive)
        }
        .buttonStyle(PressableButtonStyle())
        .frame(maxWidth: .infinity)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    @ViewBuilder
    private func toolGlyph(systemName: String, isActive: Bool) -> some View {
        let glyph = Image(systemName: systemName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(isActive ? Color.primary : Color.primary.opacity(0.6))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 44, height: 44)
            .contentShape(Circle())

        if isActive {
            glyph.adaptiveGlass(in: Circle(), tint: .white.opacity(0.12))
        } else {
            glyph
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            Text(Localized.noTrackSelected)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helper Functions

    private var lyricsButton: some View {
        Button {
            toggle(.lyrics)
        } label: {
            toolGlyph(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble", isActive: showLyrics)
                .overlay(alignment: .topTrailing) {
                    if isLoadingLyrics {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
        }
        .buttonStyle(PressableButtonStyle())
        .frame(maxWidth: .infinity)
        .accessibilityLabel(Localized.lyrics)
        .accessibilityAddTraits(showLyrics ? .isSelected : [])
    }

    private var sleepTimerButton: some View {
        Menu {
            Button(Localized.sleepTimer15Minutes) {
                startSleepTimer(minutes: 15)
            }
            Button(Localized.sleepTimer30Minutes) {
                startSleepTimer(minutes: 30)
            }
            Button(Localized.sleepTimer45Minutes) {
                startSleepTimer(minutes: 45)
            }
            Button(Localized.sleepTimer60Minutes) {
                startSleepTimer(minutes: 60)
            }

            if playerEngine.sleepTimerEndDate != nil {
                Divider()

                Button(Localized.cancelSleepTimer, role: .destructive) {
                    playerEngine.cancelSleepTimer()
                }
            }
        } label: {
            toolGlyph(systemName: "moon.zzz", isActive: playerEngine.sleepTimerEndDate != nil)
        }
        .menuOrder(.fixed)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(Localized.sleepTimer)
    }

    private func startSleepTimer(minutes: Int) {
        playerEngine.startSleepTimer(minutes: minutes)
    }

    /// Adopts a specific lrclib record the user picked over the automatic match.
    private func applyLyricsAlternative(_ id: Int) {
        guard let currentTrack = playerEngine.currentTrack else { return }

        isLoadingLyrics = true
        Task {
            let lyrics = await LyricsManager.shared.useAlternative(id, for: currentTrack)
            await MainActor.run {
                if let lyrics { currentLyrics = lyrics }
                isLoadingLyrics = false
            }
        }
    }

    /// - Parameter forceRefresh: ignore a remembered "lrclib has nothing for
    ///   this song" and ask again. Backs the retry on the not-found card.
    private func loadLyrics(forceRefresh: Bool = false) {
        guard let currentTrack = playerEngine.currentTrack else { return }

        isLoadingLyrics = true
        if forceRefresh { currentLyrics = nil }

        Task {
            let lyrics = forceRefresh
                ? await LyricsManager.shared.refreshLyrics(for: currentTrack)
                : await LyricsManager.shared.getLyrics(for: currentTrack)

            await MainActor.run {
                // A quick skip can finish this lookup after the next track
                // has started; never show the previous song's lyrics.
                guard playerEngine.currentTrack?.stableId == currentTrack.stableId else { return }
                currentLyrics = lyrics
                isLoadingLyrics = false
            }
        }
    }
    
    private func loadAllArtworks() async {
        await loadCurrentArtwork()
        await loadNextArtwork()
        await loadPreviousArtwork()
    }
    
    private func loadCurrentArtwork() async {
        guard let track = playerEngine.currentTrack else {
            currentArtwork = nil
            return
        }

        let trackId = track.stableId
        let artwork = await artworkManager.getArtwork(for: track)
        guard playerEngine.currentTrack?.stableId == trackId else { return }
        currentArtwork = artwork
    }
    
    private func loadNextArtwork() async {
        let currentTrackId = playerEngine.currentTrack?.stableId
        let nextTrack = getNextTrack()
        guard let track = nextTrack else {
            guard playerEngine.currentTrack?.stableId == currentTrackId else { return }
            nextArtwork = nil
            return
        }

        let nextTrackId = track.stableId
        let artwork = await artworkManager.getArtwork(for: track)
        guard playerEngine.currentTrack?.stableId == currentTrackId,
              getNextTrack()?.stableId == nextTrackId else { return }
        nextArtwork = artwork
    }
    
    private func loadPreviousArtwork() async {
        let currentTrackId = playerEngine.currentTrack?.stableId
        let prevTrack = getPreviousTrack()
        guard let track = prevTrack else {
            guard playerEngine.currentTrack?.stableId == currentTrackId else { return }
            previousArtwork = nil
            return
        }

        let previousTrackId = track.stableId
        let artwork = await artworkManager.getArtwork(for: track)
        guard playerEngine.currentTrack?.stableId == currentTrackId,
              getPreviousTrack()?.stableId == previousTrackId else { return }
        previousArtwork = artwork
    }
    
    private func getNextTrack() -> Track? {
        let queue = playerEngine.playbackQueue
        let currentIndex = playerEngine.currentIndex
        
        guard !queue.isEmpty else { return nil }
        
        if currentIndex < queue.count - 1 {
            // Normal next track
            return queue[currentIndex + 1]
        } else {
            // Wraparound to first track
            return queue[0]
        }
    }
    
    private func getPreviousTrack() -> Track? {
        let queue = playerEngine.playbackQueue
        let currentIndex = playerEngine.currentIndex
        
        guard !queue.isEmpty else { return nil }
        
        if currentIndex > 0 {
            // Normal previous track
            return queue[currentIndex - 1]
        } else {
            // Wraparound to last track
            return queue[queue.count - 1]
        }
    }
    
    /// The library the album and artist screens are built from, fetched when
    /// the user navigates. It used to load on every open of the player, on
    /// the main thread, for a tap that rarely comes.
    private func libraryTracks() -> [Track] {
        (try? appCoordinator.getAllTracks()) ?? []
    }
    
    private func checkFavoriteStatus() {
        guard let currentTrack = playerEngine.currentTrack else {
            isFavorite = false
            return
        }
        
        do {
            isFavorite = try DatabaseManager.shared.isFavorite(trackStableId: currentTrack.stableId)
        } catch {
            print("Failed to check favorite status: \(error)")
            isFavorite = false
        }
    }
    
    private func toggleFavorite() {
        guard let currentTrack = playerEngine.currentTrack else { return }
        
        do {
            try appCoordinator.toggleFavorite(trackStableId: currentTrack.stableId)
            isFavorite.toggle()
        } catch {
            print("Failed to toggle favorite: \(error)")
        }
    }
    
    /// Everything the player derives from the current track, resolved once
    /// per track instead of with database reads inside `body`.
    private func refreshTrackContext() async {
        guard let track = playerEngine.currentTrack else {
            trackContext = PlayerTrackContext()
            palette = nil
            return
        }

        let trackId = track.stableId
        let context = PlayerTrackContext(
            album: track.albumId.flatMap { albumId in
                try? DatabaseManager.shared.read { db in try Album.fetchOne(db, key: albumId) }
            },
            artist: track.artistId.flatMap { artistId in
                try? DatabaseManager.shared.read { db in try Artist.fetchOne(db, key: artistId) }
            },
            artistDisplayName: try? DatabaseManager.shared.getArtistDisplayName(
                forTrackStableId: track.stableId,
                fallbackArtistId: track.artistId
            )
        )
        guard playerEngine.currentTrack?.stableId == trackId else { return }
        trackContext = context

        // A small thumbnail is plenty for a 3x3 colour sample; 160px is the
        // size the mini player already cached, so this is usually a cache hit.
        guard let thumbnail = await artworkManager.getThumbnail(for: track, maxPixelSize: 160),
              let newPalette = await ArtworkPaletteExtractor.palette(for: trackId, image: thumbnail),
              playerEngine.currentTrack?.stableId == trackId else {
            if playerEngine.currentTrack?.stableId == trackId { palette = nil }
            return
        }
        palette = newPalette
    }
}

/// The player's one artwork, placed by interpolating between the full-size
/// slot and the lyrics-header slot. Only `progress` animates, so a slot that
/// is measured or corrected mid-flight bends the path instead of snapping it.
private struct FlyingArtwork: View, @MainActor Animatable {
    let image: UIImage?
    let from: CGRect
    let to: CGRect
    var progress: CGFloat
    var scale: CGFloat
    var shadowStrength: CGFloat

    nonisolated var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(progress, AnimatablePair(scale, shadowStrength)) }
        set {
            progress = newValue.first
            scale = newValue.second.first
            shadowStrength = newValue.second.second
        }
    }

    var body: some View {
        let t = min(max(progress, 0), 1)
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        let rect = CGRect(
            x: lerp(from.minX, to.minX),
            y: lerp(from.minY, to.minY),
            width: lerp(from.width, to.width),
            height: lerp(from.height, to.height)
        )
        return ArtworkTile(
            image: image,
            cornerRadius: lerp(18, 10),
            placeholderFont: .system(size: min(80, max(rect.width, 1) * 0.2))
        )
        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
        // The shadow is drawn once at a fixed size by a plain shape behind
        // the artwork; only its opacity follows play/pause. Animating the
        // radius re-rendered the blurred artwork every frame of the spring.
        .background {
            RoundedRectangle(cornerRadius: lerp(18, 10), style: .continuous)
                .fill(.black)
                .shadow(color: .black.opacity(0.45), radius: 26, x: 0, y: 16)
                .opacity(0.35 + 0.65 * shadowStrength)
        }
        .scaleEffect(scale)
        .position(x: rect.midX, y: rect.midY)
    }
}

private struct PlayerTrackContext {
    var album: Album?
    var artist: Artist?
    var artistDisplayName: String?
}

/// Owns the fast-changing progress observation so the complete PlayerView
/// (artwork, sheets and controls) is not recomputed four times per second.
private struct PlayerProgressSection: View {
    @ObservedObject private var progress = PlayerEngine.shared.progress
    let duration: TimeInterval
    let onSeek: (TimeInterval) async -> Void

    private var fraction: Double {
        guard duration > 0 else { return 0 }
        let value = progress.playbackTime / duration
        guard value.isFinite else { return 0 }
        return max(0, min(1, value))
    }

    var body: some View {
        ElasticScrubber(
            progress: fraction,
            duration: duration,
            onSeek: { await onSeek($0 * duration) }
        )
    }
}

/// Keeps lyric timing updates inside the lyrics content instead of
/// invalidating the player and any underlying list.
private struct LiveLyrics: View {
    @ObservedObject private var progress = PlayerEngine.shared.progress
    let lyrics: Lyrics?
    let isLoading: Bool
    let isPlaying: Bool
    let onRetry: (() -> Void)?
    let track: Track?
    let onSelectAlternative: ((Int) -> Void)?

    var body: some View {
        LyricsView(
            lyrics: lyrics,
            currentTime: progress.playbackTime,
            isLoading: isLoading,
            isPlaying: isPlaying,
            onSeek: { time in
                Task { await PlayerEngine.shared.seek(to: time) }
            },
            onRetry: onRetry,
            loadAlternatives: track.map { track in
                { await LyricsManager.shared.alternatives(for: track) }
            },
            onSelectAlternative: onSelectAlternative
        )
    }
}

struct MiniPlayerView: View {
    @ObservedObject private var playerEngine = PlayerEngine.shared
    @ObservedObject private var artworkManager = ArtworkManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var currentArtwork: UIImage?
    @State private var artistName: String?
    @State private var dragOffset: CGFloat = 0
    @State private var skipTrigger = 0
    @State private var pendingPlaying: Bool?
    @State private var settings = DeleteSettings.load()
    @Environment(\.colorScheme) private var colorScheme

    private let cardShape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        VStack(spacing: 8) {
            if let message = playerEngine.playbackErrorMessage, playerEngine.currentTrack != nil {
                errorBanner(message)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let track = playerEngine.currentTrack {
                card(track: track)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: 700)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.82), value: playerEngine.currentTrack == nil)
        .animation(.smooth(duration: 0.3), value: playerEngine.playbackErrorMessage)
        .fullScreenCover(isPresented: $isExpanded) {
            PlayerView(closeWithoutTransition: {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { isExpanded = false }
            })
                .accentColor(settings.backgroundColorChoice.color)
                .presentationBackground(.clear)
                // A dark presentation gives the player a white status bar, as
                // over any dark backdrop; what should follow the app's own
                // appearance reads `appColorScheme`.
                .environment(\.appColorScheme, colorScheme)
                .preferredColorScheme(.dark)
        }
        .task(id: playerEngine.currentTrack?.stableId) {
            guard let track = playerEngine.currentTrack else {
                currentArtwork = nil
                artistName = nil
                return
            }
            artistName = try? DatabaseManager.shared.getArtistDisplayName(
                forTrackStableId: track.stableId,
                fallbackArtistId: track.artistId
            )
            let artwork = await artworkManager.getThumbnail(for: track, maxPixelSize: 160)
            guard playerEngine.currentTrack?.stableId == track.stableId else { return }
            withAnimation(.easeInOut(duration: 0.25)) { currentArtwork = artwork }
            // Warm what the full player starts from, so opening it shows the
            // real cover and backdrop on its first frame (see PlayerView.init).
            if let artwork {
                _ = await ArtworkPaletteExtractor.palette(for: track.stableId, image: artwork)
            }
            _ = await artworkManager.getArtwork(for: track)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToArtistFromPlayer"))) { _ in
            isExpanded = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToAlbumFromPlayer"))) { _ in
            isExpanded = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
            settings = DeleteSettings.load()
        }
    }

    private func card(track: Track) -> some View {
        HStack(spacing: 12) {
            artworkThumb
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let artistName {
                    Text(artistName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .id(track.stableId)
            .transition(.blurReplace)
            .frame(maxWidth: .infinity, alignment: .leading)

            // buttonStyle(.plain) plus a content shape per button stop the
            // card's tap gesture (which expands the player) from taking these.
            HStack(spacing: 2) {
                Button {
                    ResponsiveTransport.toggle(playerEngine, pending: $pendingPlaying)
                } label: {
                    PlayPauseGlyph(isPlaying: pendingPlaying ?? playerEngine.displaysPlaying, size: 22)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel((pendingPlaying ?? playerEngine.displaysPlaying) ? Localized.pause : Localized.play)

                Button {
                    skipTrigger += 1
                    Task { await playerEngine.nextTrack() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 20))
                        .symbolEffect(.bounce, options: .speed(1.6), value: skipTrigger)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Localized.nextTrack)
            }
            .buttonStyle(PressableButtonStyle())
            .foregroundStyle(.primary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .animation(.smooth(duration: 0.3), value: track.stableId)
        .overlay(alignment: .bottom) {
            MiniPlayerProgressBar(
                duration: playerEngine.duration,
                accentColor: settings.backgroundColorChoice.color
            )
            .padding(.horizontal, 22)
        }
        .clipShape(cardShape)
        .contentShape(cardShape)
        .adaptiveGlass(in: cardShape, interactive: true)
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 6)
        .offset(x: dragOffset)
        .onTapGesture {
            // The cover would otherwise open on top of a keyboard left up
            // by a list's search field.
            dismissSearchKeyboard()
            // No system transition: the card raises itself (PlayerCard).
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { isExpanded = true }
        }
        .gesture(swipeToSkip)
        .sensoryFeedback(.impact(weight: .light), trigger: skipTrigger)
        .onAppear { ResponsiveTransport.prepare() }
        .accessibilityAction(named: Localized.previousTrack) {
            Task { await playerEngine.previousTrack() }
        }
    }

    private var artworkThumb: some View {
        ArtworkTile(image: currentArtwork, cornerRadius: 10)
    }

    /// Horizontal swipe on the card skips, with a little rubber-band so the
    /// card follows the finger before it springs back.
    private var swipeToSkip: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = value.translation.width * 0.35
            }
            .onEnded { value in
                let distance = value.translation.width
                let projected = value.predictedEndTranslation.width
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    dragOffset = 0
                }
                guard abs(distance) > abs(value.translation.height),
                      abs(projected) > 80 || abs(distance) > 60 else { return }
                skipTrigger += 1
                Task {
                    if distance < 0 {
                        await playerEngine.nextTrack()
                    } else {
                        await playerEngine.previousTrack()
                    }
                }
            }
    }

    private func errorBanner(_ message: String) -> some View {
        // A track that cannot be played says so here, instead of sitting
        // silent and selected.
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                playerEngine.playbackErrorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Localized.close)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .adaptiveGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: .orange.opacity(0.15))
        .accessibilityElement(children: .combine)
    }
}

/// A render-only progress leaf. Scaling a full-width rectangle changes only
/// its transform; it does not resize the safe-area inset or ask the underlying
/// Library List to perform a collection diff on every playback tick.
private struct MiniPlayerProgressBar: View {
    @ObservedObject private var progress = PlayerEngine.shared.progress
    let duration: TimeInterval
    let accentColor: Color

    private var fraction: CGFloat {
        guard duration > 0 else { return 0 }
        let value = progress.playbackTime / duration
        return CGFloat(max(0, min(1, value.isFinite ? value : 0)))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))

            Rectangle()
                .fill(accentColor)
                .scaleEffect(x: fraction, y: 1, anchor: .leading)
                .animation(.linear(duration: 0.25), value: fraction)
        }
        .frame(height: 2)
        .clipped()
    }
}


struct TrackRowView: View, @MainActor Equatable {
    let track: Track
    let artistName: String?
    
    let onTap: () -> Void
    let playlist: Playlist?
    let showDirectDeleteButton: Bool
    let onEnterBulkMode: (() -> Void)?

    /// Everything the closures above capture that can change without any of
    /// the compared fields changing.
    ///
    /// `.equatable()` skips `body` whenever `==` answers true, and the stored
    /// view - including `onTap` - is kept as it was. So a closure that reads
    /// the parent's state acts on whatever that state held the last time this
    /// row actually re-rendered. That is how searching a list produced a queue
    /// built from the *unfiltered* list: the surviving rows compared equal, so
    /// they kept the `onTap` that had captured the pre-search track array.
    /// Anything a closure reads has to be folded in here.
    /// Composed by the parent; see `TrackListContentView.rowContextIdentity`.
    let contextIdentity: String
    
    @EnvironmentObject private var appCoordinator: AppCoordinator
    
    // Internal state only (does not trigger external redraws)
    @State private var isFavorite = false
    @State private var showPlaylistDialog = false
    @State private var artworkImage: UIImage?
    @State private var showDeleteConfirmation = false
    @State private var deleteSettings = DeleteSettings.load()
    
    /// Read from `NowPlayingStatus` in `body`, so Observation re-renders
    /// this row alone when the current song changes or pauses, and the list
    /// around it does not re-render at all.
    private var isCurrentlyPlaying: Bool {
        NowPlayingStatus.shared.currentStableId == track.stableId
    }
    
    static func == (lhs: TrackRowView, rhs: TrackRowView) -> Bool {
        return lhs.track.stableId == rhs.track.stableId &&
        lhs.artistName == rhs.artistName &&
        lhs.playlist?.id == rhs.playlist?.id &&
        lhs.showDirectDeleteButton == rhs.showDirectDeleteButton &&
        lhs.contextIdentity == rhs.contextIdentity
    }

    private func resolvedArtistName() -> String? {
        if let artistName, !artistName.isEmpty {
            return artistName
        }

        return try? DatabaseManager.shared.getArtistDisplayName(
            forTrackStableId: track.stableId,
            fallbackArtistId: track.artistId
        )
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Tappable Content Area
            HStack(spacing: 12) {
                ArtworkTile(image: artworkImage)
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body)
                        .foregroundStyle(isCurrentlyPlaying ? deleteSettings.backgroundColorChoice.color : .primary)
                        .lineLimit(1)

                    if let resolvedArtistName = resolvedArtistName() {
                        Text(resolvedArtistName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if isCurrentlyPlaying {
                    let isAudioPlaying = NowPlayingStatus.shared.isPlaying

                    EqualizerBarsExact(
                        color: deleteSettings.backgroundColorChoice.color,
                        isActive: isAudioPlaying,
                        isLarge: true,
                        trackId: track.stableId
                    )
                    .id("\(isAudioPlaying)-\(track.stableId)")
                    .padding(.trailing, 4)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onTap()
            }

            // MARK: - Menu / Action Area
            if showDirectDeleteButton {
                Button(action: {
                    removeFromPlaylist()
                }) {
                    Image(systemName: "trash")
                        .font(.title2)
                        .foregroundColor(.red)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(.red.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, 8)
            } else {
                Menu {
                    if let onEnterBulkMode = onEnterBulkMode {
                        Button(action: { onEnterBulkMode() }) {
                            Label(Localized.select, systemImage: "checkmark.circle")
                        }
                    }
                    
                    Button(action: {
                        do {
                            try appCoordinator.toggleFavorite(trackStableId: track.stableId)
                            isFavorite.toggle()
                        } catch { print("Failed to toggle favorite: \(error)") }
                    }) {
                        HStack {
                            Image(systemName: isFavorite ? "heart.slash" : "heart")
                            Text(isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs)
                        }
                    }
                    
                    if let artistId = track.artistId,
                       let artist = try? DatabaseManager.shared.read({ db in try Artist.fetchOne(db, key: artistId) }),
                       let allArtistTracks = try? DatabaseManager.shared.getTracksByArtistId(artistId) {
                        NavigationLink(destination: ArtistDetailScreen(artist: artist, allTracks: allArtistTracks)) {
                            Label(Localized.showArtistPage, systemImage: "person.circle")
                        }
                    }
                    
                    Button(action: { showPlaylistDialog = true }) {
                        Label(Localized.addToPlaylistEllipsis, systemImage: "rectangle.stack.badge.plus")
                    }
                    
                    Button(action: { showDeleteConfirmation = true }) {
                        Label(Localized.deleteFile, systemImage: "trash")
                    }
                    .foregroundColor(.red)
                    
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .frame(height: 64)
        .animation(.smooth(duration: 0.25), value: isCurrentlyPlaying)
        .sheet(isPresented: $showPlaylistDialog) {
            PlaylistSelectionView(track: track)
                .accentColor(deleteSettings.backgroundColorChoice.color)
        }
        .alert(Localized.deleteFile, isPresented: $showDeleteConfirmation) {
            Button(Localized.delete, role: .destructive) { deleteFile() }
            Button(Localized.cancel, role: .cancel) { }
        } message: {
            Text(Localized.deleteFileConfirmation(track.title))
        }
        .onAppear {
            isFavorite = (try? appCoordinator.isFavorite(trackStableId: track.stableId)) ?? false
            if artworkImage == nil { loadArtwork() }
        }
        .reloadsArtwork(for: track.stableId) { loadArtwork() }
    }
    
    private func loadArtwork() {
        Task {
            let image = await ArtworkManager.shared.getThumbnail(for: track)
            withAnimation(.easeOut(duration: 0.2)) { artworkImage = image }
        }
    }
    
    private func deleteFile() {
        Task {
            do {
                let settings = DeleteSettings.load()
                if settings.deleteFromLibraryOnly {
                    DeleteSettings.addExcludedTrack(track.stableId, path: track.path, modificationDate: track.modificationDate)
                } else {
                    do {
                        try FileManager.default.removeItem(at: URL(fileURLWithPath: track.path))
                    } catch {
                        print("⚠️ Could not remove file from disk: \(error.localizedDescription)")
                    }
                }

                try await DatabaseManager.shared.deleteTrack(byStableId: track.stableId)
                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
            } catch {
                print("❌ Failed to delete track: \(error)")
            }
        }
    }
    
    private func removeFromPlaylist() {
        guard let playlist = playlist, let playlistId = playlist.id else { return }
        Task {
            do {
                try appCoordinator.removeFromPlaylist(playlistId: playlistId, trackStableId: track.stableId)
                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
            } catch { print("❌ Failed to remove from playlist: \(error)") }
        }
    }
}
