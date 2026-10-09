//
//  LyricsView.swift
//  Cosmos Music Player
//
//  Lyrics display with synchronized, tappable scrolling
//

import SwiftUI
import UIKit

// MARK: - Row model

/// One scrollable row of the synced view.
///
/// Instrumental breaks get a row of their own instead of leaving the last sung
/// line highlighted for half a minute, so a long intro or solo still shows the
/// song moving forward - and stays tappable like any other row.
/// One word of a lyric line, measured in both the unit time is spent in and
/// the unit the sweep is drawn in.
private struct LyricUnit: Equatable {
    /// What the singer spends: roughly constant per syllable within a phrase.
    let syllables: Double
    /// What the renderer spends: the front is drawn across glyphs.
    let characters: Double
}

/// Syllable estimation, the unit singing is actually measured in.
///
/// Characters are a poor proxy and the error is not small: "through" is seven
/// characters and one syllable, "idea" is four characters and three. Timing a
/// sweep per character holds the front on "through" for seven counts and races
/// it past "idea", which is precisely the arrhythmia this is meant to remove.
///
/// The rigorous answer is phoneme-level forced alignment against the audio, and
/// the research is unambiguous that this is what real systems do - but it needs
/// singing-adapted acoustic models, not the speech ones on the device, and it
/// is far too heavy to run per track here. Counting syllables is the same unit
/// that work uses as its quantum, arrived at from the text alone.
private enum LyricProsody {
    static func units(of line: String) -> [LyricUnit] {
        line
            .split(whereSeparator: { $0.isWhitespace })
            .map { word in
                LyricUnit(
                    syllables: Double(syllables(in: word)),
                    // Trailing space included so the front clears a word before
                    // it starts the next, rather than jumping the gap.
                    characters: Double(word.count + 1)
                )
            }
    }

    static func syllableCount(of line: String) -> Int {
        line
            .split(whereSeparator: { $0.isWhitespace })
            .reduce(0) { $0 + syllables(in: $1) }
    }

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]

    private static func syllables(in word: Substring) -> Int {
        var syllabic = 0
        var letters = ""

        for character in word.lowercased() {
            // Han, Kana and Hangul carry about a syllable each, so they are
            // counted directly instead of hunting for vowels that are not there.
            if isSyllabic(character) {
                syllabic += 1
            } else if character.isLetter {
                letters.append(character)
            }
        }

        guard !letters.isEmpty else {
            return max(syllabic, word.isEmpty ? 0 : 1)
        }

        var count = 0
        var previousWasVowel = false
        for character in letters {
            let isVowel = vowels.contains(character)
            if isVowel && !previousWasVowel { count += 1 }
            previousWasVowel = isVowel
        }

        // Endings English writes but does not sing as their own syllable.
        if letters.count > 2 {
            if letters.hasSuffix("e") {
                // ...except after a consonant + "l", where the "le" *is* the
                // syllable: "people" and "little" are two, not one.
                if !endsInConsonantLE(letters) { count -= 1 }
            } else if letters.hasSuffix("ed") {
                // "moved" is one syllable; "wanted" and "needed" are two,
                // because -ed after t or d has to be voiced.
                if !letters.hasSuffix("ted") && !letters.hasSuffix("ded") { count -= 1 }
            } else if letters.hasSuffix("es") {
                // Same shape: "makes" is one, "boxes" and "wishes" are two.
                if !Self.voicedESEndings.contains(where: letters.hasSuffix) { count -= 1 }
            }
        }

        return max(count, 1) + syllabic
    }

    private static let voicedESEndings = ["ses", "xes", "zes", "ches", "shes", "ges", "ces"]

    private static func endsInConsonantLE(_ letters: String) -> Bool {
        guard letters.count >= 3, letters.hasSuffix("le") else { return false }
        let beforeL = letters[letters.index(letters.endIndex, offsetBy: -3)]
        return !vowels.contains(beforeL)
    }

    private static func isSyllabic(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana, Katakana
             0x3400...0x4DBF,   // CJK extension A
             0x4E00...0x9FFF,   // CJK unified
             0xAC00...0xD7AF:   // Hangul syllables
            return true
        default:
            return false
        }
    }
}

private struct LyricRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case line(String)
        case gap
    }

    let id: Int
    let kind: Kind
    /// When this row becomes the active one.
    let start: TimeInterval
    /// When the next row takes over; `.infinity` for the last row.
    let end: TimeInterval
    /// When the words are expected to have finished being sung - which is not
    /// the same instant the next line begins. Only consulted when `words` is
    /// nil; see `perLineRates`.
    let sweepEnd: TimeInterval
    /// Exact word timings, when the source had them. Present only for Enhanced
    /// LRC; everything from lrclib falls back to the estimate above.
    var words: [LyricsWord]? = nil
    /// Word spans used by the estimated sweep when `words` is nil.
    var units: [LyricUnit] = []
}

private enum LyricRowBuilder {
    /// Breaks shorter than this read as ordinary breathing room between lines
    /// and stay invisible; anything longer earns a progress row.
    static let minimumBreak: TimeInterval = 8
    /// LRC files only carry line *start* times, so a break cannot begin the
    /// instant its preceding line does. Assume the line keeps being sung for
    /// this long before the interlude starts.
    static let lineTail: TimeInterval = 3
    /// An intro needs less slack than a mid-song break: nothing is being sung
    /// before the first line, so the whole span is genuinely instrumental.
    static let minimumIntro: TimeInterval = 5

    /// A sweep never finishes faster than this, however short the line, so a
    /// one-word lyric still reads as filling rather than snapping on.
    static let minimumSweep: TimeInterval = 0.45
    /// What the last line gets, having no successor to measure against.
    static let finalLineSweep: TimeInterval = 4

    static func rows(for lines: [LyricsLine]) -> [LyricRow] {
        // Timestamps must not go backwards: a malformed LRC would otherwise
        // break the binary search that finds the active row.
        var lineStarts: [TimeInterval] = []
        var previousStart: TimeInterval?
        for line in lines {
            let rawStart = line.timestamp ?? previousStart ?? 0
            let start = max(rawStart, previousStart ?? rawStart)
            lineStarts.append(start)
            previousStart = start
        }

        let rates = perLineRates(for: lines, starts: lineStarts)

        var built: [(kind: LyricRow.Kind, start: TimeInterval, sweepEnd: TimeInterval, words: [LyricsWord]?, units: [LyricUnit])] = []

        for (index, line) in lines.enumerated() {
            let start = lineStarts[index]

            if index > 0 {
                let previous = lineStarts[index - 1]
                if start - previous >= minimumBreak {
                    built.append((.gap, previous + lineTail, previous + lineTail, nil, []))
                }
            } else if start >= minimumIntro {
                built.append((.gap, 0, 0, nil, []))
            }

            // The gap to the *next line*, not to whatever row comes next: an
            // interlude row may be inserted in between, and the words of this
            // line are no shorter for it.
            let gapToNextLine = index + 1 < lineStarts.count
                ? lineStarts[index + 1] - start
                : TimeInterval.infinity

            built.append((
                .line(line.text),
                start,
                start + sweepDuration(
                    of: line.text,
                    gapToNextLine: gapToNextLine,
                    rate: rates[index]
                ),
                line.words,
                LyricProsody.units(of: line.text)
            ))
            previousStart = start
        }

        return built.enumerated().map { index, item in
            let end = index + 1 < built.count ? built[index + 1].start : TimeInterval.infinity
            return LyricRow(
                id: index,
                kind: item.kind,
                start: item.start,
                end: end,
                sweepEnd: item.sweepEnd,
                words: item.words,
                units: item.units
            )
        }
    }

    /// How long this line's words should take to sweep.
    private static func sweepDuration(
        of text: String,
        gapToNextLine: TimeInterval,
        rate: TimeInterval?
    ) -> TimeInterval {
        let length = Double(singableLength(text))

        guard let rate, length > 0 else {
            // No usable rhythm to work from: fall back to the old behaviour of
            // spreading the sweep across the whole gap.
            return gapToNextLine.isFinite ? max(gapToNextLine, minimumSweep) : finalLineSweep
        }

        // Syllables measure words, not held notes. A sung "Oh" is one syllable
        // and can occupy four seconds, and finishing its sweep in half a second
        // is as wrong as the old behaviour of crawling across the entire gap -
        // just in the other direction. Giving every line a floor of roughly a
        // third of its gap covers melisma without letting a line that really
        // does end early drift back to trailing the voice.
        let heldNoteFloor = gapToNextLine.isFinite
            ? min(gapToNextLine * 0.35, 2.5)
            : 0
        let estimated = max(length * rate, minimumSweep, heldNoteFloor)

        // Never past the next line, and never longer than a plausible tail on
        // the last line.
        return gapToNextLine.isFinite ? min(estimated, gapToNextLine) : min(estimated, finalLineSweep)
    }

    /// Syllables, not characters: see LyricProsody. Estimating the rate in the
    /// same unit the sweep is spent in is what keeps the two consistent, and it
    /// makes the number itself meaningful - seconds per syllable is comparable
    /// across languages in a way seconds per character is not.
    private static func singableLength(_ text: String) -> Int {
        LyricProsody.syllableCount(of: text)
    }

    /// Seconds per sung character, measured per line rather than per track.
    ///
    /// Every gap between consecutive lines is an *upper bound* on how long the
    /// earlier line took to sing - it is the singing plus whatever silence
    /// follows - so the rate sits near the bottom of the distribution of
    /// gap-over-length, not in the middle of it. A low percentile lands on the
    /// lines that run straight into the next one, which are the ones actually
    /// sung at the local pace.
    ///
    /// Measured over a sliding window rather than the whole song, because a
    /// song does not keep one pace: a fast verse into a held chorus is the
    /// normal case, and a single track-wide number makes the chorus finish
    /// early and the verse trail. The track-wide rate is kept as the fallback
    /// where a window has too little evidence, and as the bound that stops one
    /// freak gap from redefining its neighbours.
    private static let rateWindow = 3

    private static func perLineRates(
        for lines: [LyricsLine],
        starts: [TimeInterval]
    ) -> [TimeInterval?] {
        let observed: [TimeInterval?] = lines.indices.map { index in
            guard index + 1 < starts.count else { return nil }
            let gap = starts[index + 1] - starts[index]
            let length = Double(singableLength(lines[index].text))
            // Very short lines and very long gaps are both poor evidence.
            // A line of fewer than two syllables is too little to measure.
            guard gap > 0.2, gap < 15, length >= 2 else { return nil }
            return gap / length
        }

        let all = observed.compactMap { $0 }
        // Too little evidence to be better than the plain gap.
        guard all.count >= 4, let global = lowPercentile(all, 0.25) else {
            return Array(repeating: nil, count: lines.count)
        }

        return lines.indices.map { index in
            let lower = max(lines.startIndex, index - rateWindow)
            let upper = min(lines.index(before: lines.endIndex), index + rateWindow)
            let samples = (lower...upper).compactMap { observed[$0] }

            guard samples.count >= 3, let local = lowPercentile(samples, 0.3) else {
                return clampRate(global)
            }

            // A section may legitimately run slower or faster than the song's
            // overall pace, but not without limit.
            return clampRate(min(max(local, global * 0.5), global * 2.5))
        }
    }

    private static func lowPercentile(_ values: [TimeInterval], _ fraction: Double) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count) * fraction)))
        return sorted[index]
    }

    /// Roughly 1.5 to 12 syllables a second - a slow ballad to a fast rap.
    /// Anything outside that says the estimate is being driven by something
    /// other than singing.
    private static func clampRate(_ rate: TimeInterval) -> TimeInterval {
        min(max(rate, 0.083), 0.66)
    }

    /// Index of the row covering `time`, or nil before the first row starts.
    static func activeIndex(in rows: [LyricRow], at time: TimeInterval) -> Int? {
        guard !rows.isEmpty else { return nil }

        var low = 0
        var high = rows.count - 1
        var match: Int?

        while low <= high {
            let mid = (low + high) / 2
            if rows[mid].start <= time {
                match = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return match
    }
}

// MARK: - Lyrics View

/// The player's in-place lyrics: drawn straight onto the artwork backdrop in
/// the Apple Music layout, with transparent edges instead of a backdrop or
/// header of its own.
struct LyricsView: View {
    let lyrics: Lyrics?
    let currentTime: TimeInterval
    let isLoading: Bool
    /// Lets the view run its own frame clock between the player's
    /// quarter-second position updates.
    var isPlaying: Bool = false
    /// Seek handler for tap-to-jump. Without one the lines stay read-only.
    var onSeek: ((TimeInterval) -> Void)? = nil
    /// Re-runs the lookup, ignoring any remembered miss.
    var onRetry: (() -> Void)? = nil
    /// Loads every lrclib record for this track, best match first.
    var loadAlternatives: (() async -> [LyricsManager.LyricsCandidate])? = nil
    /// Adopts one of them.
    var onSelectAlternative: ((Int) -> Void)? = nil

    @State private var settings = DeleteSettings.load()
    @State private var showVersionPicker = false

    @ScaledMetric(relativeTo: .body) private var plainFontSize: CGFloat = 26

    var body: some View {
        content
            .overlay(alignment: .topTrailing) {
                if copyableText != nil {
                    actionsMenu
                }
            }
            // The lyric type scales with the user's text size, but the two largest
            // accessibility steps leave room for barely a word per line.
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .sheet(isPresented: $showVersionPicker) {
                if let loadAlternatives {
                    LyricsVersionPicker(
                        accent: settings.backgroundColorChoice.color,
                        load: loadAlternatives,
                        onSelect: { id in
                            showVersionPicker = false
                            onSelectAlternative?(id)
                        }
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
                settings = DeleteSettings.load()
            }
    }

    private var actionsMenu: some View {
        Menu {
            Button {
                copyLyrics()
            } label: {
                Label(Localized.lyricsCopy, systemImage: "doc.on.doc")
            }

            if loadAlternatives != nil {
                Button {
                    showVersionPicker = true
                } label: {
                    Label(Localized.lyricsChooseVersion, systemImage: "text.line.first.and.arrowtriangle.forward")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 32, height: 32)
                .adaptiveGlass(in: Circle(), interactive: true)
        }
        .accessibilityLabel(Localized.lyricsMoreActions)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            LyricsStatusCard(
                icon: .progress,
                title: Localized.lyricsLoading,
                message: Localized.lyricsLoadingMessage
            )
        } else if let lyrics {
            if lyrics.isInstrumental {
                LyricsStatusCard(
                    icon: .symbol("music.note"),
                    title: Localized.lyricsInstrumental,
                    message: Localized.lyricsInstrumentalMessage
                )
            } else if !lyrics.syncedLyrics.isEmpty {
                SyncedLyricsScroller(
                    lines: lyrics.syncedLyrics,
                    currentTime: currentTime,
                    onSeek: onSeek,
                    isPlaying: isPlaying
                )
            } else if !lyrics.plainLyrics.isEmpty {
                plainLyricsView(lyrics.plainLyrics)
            } else {
                unavailableCard
            }
        } else {
            unavailableCard
        }
    }

    /// A miss is remembered for a week so reopening lyrics is not three
    /// fruitless network round trips - which makes an explicit way to ask again
    /// necessary rather than merely nice, for a song whose lyrics were added
    /// upstream since, or that was looked up while offline.
    private var unavailableCard: some View {
        LyricsStatusCard(
            icon: .symbol("text.badge.xmark"),
            title: Localized.lyricsUnavailable,
            message: Localized.lyricsUnavailableMessage,
            actionTitle: onRetry == nil ? nil : Localized.lyricsSearchAgain,
            action: onRetry
        )
    }

    // MARK: - Plain Lyrics

    /// Unsynced lyrics, set like the synced view: the same left-aligned bold
    /// column and the same transparent edges, without an active line.
    private func plainLyricsView(_ text: String) -> some View {
        ScrollView {
            VStack(spacing: 26) {
                ForEach(Array(stanzas(of: text).enumerated()), id: \.offset) { _, stanza in
                    Text(stanza)
                        .font(.system(size: plainFontSize, weight: .bold))
                        .foregroundColor(.white.opacity(0.92))
                        .lineSpacing(6)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 4)
            .padding(.top, 36)
            .padding(.bottom, 60)
        }
        .scrollIndicators(.hidden)
        .mask { LyricsEdgeMask(top: 36, bottom: 56) }
    }

    /// Splits on blank lines so verses and choruses keep their own breathing
    /// room instead of arriving as one undifferentiated block.
    private func stanzas(of text: String) -> [String] {
        let blocks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return blocks.isEmpty ? [text] : blocks
    }

    // MARK: - Actions

    private var copyableText: String? {
        guard let lyrics, !isLoading, !lyrics.isInstrumental else { return nil }

        if !lyrics.plainLyrics.isEmpty {
            return lyrics.plainLyrics
        }
        if !lyrics.syncedLyrics.isEmpty {
            return lyrics.syncedLyrics.map(\.text).joined(separator: "\n")
        }
        return nil
    }

    private func copyLyrics() {
        guard let copyableText else { return }
        UIPasteboard.general.string = copyableText
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

struct PlaybackClockAnchor: Equatable {
    var time: TimeInterval
    var date: Date
}

/// Transparent edges for lyrics drawn over the artwork backdrop: the text
/// itself fades out, so there is no coloured band to match the background.
private struct LyricsEdgeMask: View {
    let top: CGFloat
    let bottom: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: top)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: bottom)
        }
    }
}

// MARK: - Synced Lyrics

private struct SyncedLyricsScroller: View {
    let lines: [LyricsLine]
    let currentTime: TimeInterval
    let onSeek: ((TimeInterval) -> Void)?
    var isPlaying: Bool = false

    /// White on the artwork backdrop, for the sweep, the break dots and the
    /// resume button alike.
    private let accent = Color.white

    /// The last reported position and when it arrived. The sung line reads
    /// the time from this every display frame, so its fill glides at the
    /// screen's refresh rate instead of stepping four times a second.
    @State private var clockAnchor = PlaybackClockAnchor(time: 0, date: .distantPast)

    private func interpolatedTime(at date: Date) -> TimeInterval {
        guard isPlaying, clockAnchor.date != .distantPast else { return currentTime }
        // Capped so a stalled engine never lets the text run on ahead.
        let elapsed = min(max(date.timeIntervalSince(clockAnchor.date), 0), 0.6)
        return clockAnchor.time + elapsed
    }

    /// Where the sung line rests: the upper third, as in Apple Music.
    private let focusAnchor = UnitPoint(x: 0.5, y: 0.28)

    /// How long after the user stops scrolling before the view takes the
    /// wheel back. Long enough to read ahead a verse, short enough that the
    /// screen never feels abandoned.
    private static let resumeDelay: TimeInterval = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion


    /// Built from `lines` when they change, never in `body`.
    ///
    /// This used to be computed inline at the call site, which meant rebuilding
    /// every row - including the windowed rate estimate, with its per-line sort -
    /// on every body pass, four times a second for the whole song, purely
    /// because the playback position had ticked.
    @State private var rows: [LyricRow] = []

    /// True once the user has actually dragged the list, which parks
    /// auto-scroll and offers the way back.
    @State private var isBrowsing = false
    /// Finger is down, or momentum is still running. Auto-scroll stays out of
    /// the way even for a touch that never became a drag.
    @State private var isTouching = false
    @State private var lastInteraction = Date.distantPast
    /// Measured height of each row, used to work out how far the list moves
    /// when the active line advances.
    @State private var rowHeights: [Int: CGFloat] = [:]
    /// Each row's temporary displacement during the cascade. The list jumps
    /// by one line instantly and every row starts displaced by the same
    /// amount, then the rows spring home one after another - the staggered
    /// "lines flow upward" motion of Apple Music lyrics.
    @State private var cascadeShift: CGFloat = 0
    /// Every line is set at one size; only brightness, blur and a slight
    /// scale separate the sung line from the rest, so nothing reflows.
    @ScaledMetric(relativeTo: .title) private var fontSize: CGFloat = 30

    /// Rows this far from the sung line take part in the cascade; the rest
    /// are off screen and move with the list.
    private static let cascadeWindow = 8

    private var activeIndex: Int? {
        LyricRowBuilder.activeIndex(in: rows, at: currentTime)
    }

    var body: some View {
        GeometryReader { geometry in
            // Enough room above and below that the active row can sit at the
            // focus point whether it is the first line or the last.
            let topInset = max(60, geometry.size.height * focusAnchor.y - 20)
            let bottomInset = max(120, geometry.size.height * (1 - focusAnchor.y))

            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: topInset)

                            ForEach(rows) { row in
                                rowButton(row, proxy: proxy)
                            }

                            Color.clear.frame(height: bottomInset)
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onScrollPhaseChange { _, phase in
                        handle(phase)
                    }
                    .mask { LyricsEdgeMask(top: 44, bottom: 72) }

                    if isBrowsing {
                        resumeButton(proxy: proxy)
                            // The list now runs under the home indicator, and
                            // an inner GeometryReader reports no safe area once
                            // its parent ignores it - so this clearance is a
                            // constant. 40pt clears the indicator and merely
                            // sits a little high on devices without one.
                            .padding(.bottom, 40)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .onChange(of: activeIndex) { oldValue, newValue in
                    guard !isBrowsing, !isTouching else { return }
                    if let oldValue, let newValue, canCascade(from: oldValue, to: newValue) {
                        cascade(from: oldValue, to: newValue, proxy: proxy)
                    } else {
                        scroll(toRowAt: newValue, proxy: proxy, animated: true)
                    }
                }
                .onChange(of: currentTime) { _, _ in
                    // The playback tick doubles as the resume clock: no timer to
                    // cancel, and it only runs while there is something to
                    // follow along with.
                    guard isBrowsing, !isTouching else { return }
                    guard Date().timeIntervalSince(lastInteraction) >= Self.resumeDelay else { return }
                    resumeFollowing(proxy: proxy)
                }
                .onChange(of: lines, initial: true) { _, newLines in
                    rows = LyricRowBuilder.rows(for: newLines)
                }
                .onChange(of: currentTime, initial: true) { _, newTime in
                    clockAnchor = PlaybackClockAnchor(time: newTime, date: Date())
                }
                .onChange(of: isPlaying) { _, _ in
                    clockAnchor = PlaybackClockAnchor(time: currentTime, date: Date())
                }
                .onAppear {
                    scroll(toRowAt: activeIndex, proxy: proxy, animated: false)
                }
            }
        }
    }

    // MARK: Rows

    private func rowButton(_ row: LyricRow, proxy: ScrollViewProxy) -> some View {
        let isActive = activeIndex == row.id
        let distance = activeIndex.map { abs(row.id - $0) } ?? 99

        return Button {
            handleTap(row, proxy: proxy)
        } label: {
            rowContent(row, isActive: isActive, distance: distance)
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.97))
        .disabled(onSeek == nil)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            rowHeights[row.id] = height
        }
        .offset(y: distance <= Self.cascadeWindow ? cascadeShift : 0)
        .animation(distance <= Self.cascadeWindow ? cascadeAnimation(for: row) : nil, value: cascadeShift)
        .id(row.id)
        .accessibilityLabel(accessibilityLabel(for: row))
        .accessibilityHint(onSeek == nil ? "" : Localized.lyricsSeekHint)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    @ViewBuilder
    private func rowContent(_ row: LyricRow, isActive: Bool, distance: Int) -> some View {
        Group {
            switch row.kind {
            case .line(let text):
                // Always wrapped, paused unless this is the sung line, so a
                // line keeps its identity when it becomes active. With Reduce
                // Motion the clock never runs and the sweep steps with playback.
                TimelineView(.animation(minimumInterval: nil, paused: !(isActive && isPlaying) || reduceMotion)) { context in
                    LyricLineText(
                        text: text,
                        font: .system(size: fontSize, weight: .bold),
                        sweep: isActive ? lineSweep(row, at: interpolatedTime(at: context.date)) : nil
                    )
                }
            case .gap:
                LyricsBreakIndicator(
                    progress: breakProgress(row),
                    isActive: isActive,
                    accent: accent
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        // One height whether active or not, so the cascade can predict
        // exactly how far the list moves.
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .scaleEffect(isActive ? 1.0 : 0.97, anchor: .leading)
        // Depth of field. The distant lines were previously only faded, which
        // reads as "dim text"; softening them as well is what makes the sung
        // line sit in front of the others rather than merely brighter than them.
        .blur(radius: blurRadius(distance: distance, isActive: isActive))
        .opacity(lineOpacity(distance: distance, isActive: isActive))
        .animation(rowAnimation, value: isActive)
        .animation(rowAnimation, value: distance)
    }

    /// How far through the active line's words we are, 0...1.
    ///
    /// Measured against `sweepEnd` - when the phrase is expected to finish
    /// being sung - rather than against when the next line starts. Those are
    /// only the same thing when one line runs straight into the next; the rest
    /// of the time the difference is a breath, and sweeping across it made the
    /// fill visibly trail the voice. Past that point the line simply holds full.
    private func lineSweep(_ row: LyricRow, at time: TimeInterval) -> Double {
        if let words = row.words, words.count > 1 {
            return wordSweep(words, fallbackEnd: row.sweepEnd, at: time)
        }

        return estimatedSweep(row, at: time)
    }

    /// The sweep for a line with no word timings.
    ///
    /// Time is spent per **syllable** and the front is drawn per **character**,
    /// which are not the same distribution and were previously conflated. A
    /// purely linear front crosses "through" - one syllable, seven glyphs - at
    /// the same speed it crosses "I remember", and the result reads as a
    /// mechanical wipe rather than as singing. Allocating the line's duration
    /// by syllable and then converting that position into a glyph position lets
    /// the front dwell on long words and skip across short ones, which is the
    /// rhythm the words themselves imply.
    private func estimatedSweep(_ row: LyricRow, at time: TimeInterval) -> Double {
        guard row.sweepEnd > row.start else { return 1 }
        let elapsed = min(max((time - row.start) / (row.sweepEnd - row.start), 0), 1)

        let totalSyllables = row.units.reduce(0) { $0 + $1.syllables }
        let totalCharacters = row.units.reduce(0) { $0 + $1.characters }
        // Nothing to distribute across: fall back to the plain linear front.
        guard totalSyllables > 0, totalCharacters > 0 else { return elapsed }

        let target = totalSyllables * elapsed
        var syllables: Double = 0
        var characters: Double = 0

        for unit in row.units {
            if syllables + unit.syllables <= target {
                syllables += unit.syllables
                characters += unit.characters
                continue
            }

            if unit.syllables > 0 {
                let fraction = (target - syllables) / unit.syllables
                characters += unit.characters * min(max(fraction, 0), 1)
            }
            break
        }

        return min(max(characters / totalCharacters, 0), 1)
    }

    /// Exact sweep from Enhanced LRC word timings.
    ///
    /// Returns a *character* fraction, not a time fraction, because that is
    /// what the renderer spends against typographic width: the front has to
    /// reach the end of a word exactly when the next word starts, and words are
    /// not equal length. Time alone would put it in the middle of "tomorrow"
    /// while the singer is already on the next word.
    private func wordSweep(_ words: [LyricsWord], fallbackEnd: TimeInterval, at time: TimeInterval) -> Double {
        let lengths = words.map { Double($0.text.count) }
        let total = lengths.reduce(0, +)
        guard total > 0, let first = words.first else { return 1 }
        guard time > first.timestamp else { return 0 }

        var consumed: Double = 0

        for index in words.indices {
            let start = words[index].timestamp
            // A trailing empty-text entry is the line's closing marker, so the
            // last real word ends exactly where the format says it does.
            let end = index + 1 < words.count ? words[index + 1].timestamp : fallbackEnd

            if time >= end {
                consumed += lengths[index]
                continue
            }

            if time > start, end > start {
                consumed += lengths[index] * ((time - start) / (end - start))
            }
            break
        }

        return min(max(consumed / total, 0), 1)
    }

    private func accessibilityLabel(for row: LyricRow) -> String {
        switch row.kind {
        case .line(let text): return text
        case .gap: return Localized.lyricsInstrumentalBreak
        }
    }

    private func breakProgress(_ row: LyricRow) -> Double {
        guard row.end.isFinite, row.end > row.start else { return 0 }
        return min(max((currentTime - row.start) / (row.end - row.start), 0), 1)
    }

    // MARK: Styling

    private var rowAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.2)
            : .interpolatingSpring(mass: 0.5, stiffness: 200, damping: 20, initialVelocity: 0)
    }

    private var scrollAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.25)
            : .interpolatingSpring(mass: 1.0, stiffness: 170, damping: 25, initialVelocity: 0)
    }

    /// One fade curve for the whole stack. Brightness is carried here alone
    /// rather than split between a text colour and a view opacity, so the two
    /// cannot drift apart and the sweep below has a single thing to lift out of.
    private func lineOpacity(distance: Int, isActive: Bool) -> Double {
        if isActive { return 1.0 }
        // Apple Music keeps the neighbours readable, just recessed.
        switch distance {
        case 1: return 0.42
        case 2: return 0.34
        default: return 0.26
        }
    }

    /// Blur is capped and stops entirely past the visible window: it costs an
    /// offscreen pass per row, and rows this far out are both nearly
    /// transparent and, in practice, already scrolled off.
    private func blurRadius(distance: Int, isActive: Bool) -> CGFloat {
        guard !isActive, !reduceMotion else { return 0 }
        switch distance {
        case 1: return 0.8
        case 2: return 1.6
        case 3, 4, 5: return 2.4
        default: return 0
        }
    }

    // MARK: Resume affordance

    private func resumeButton(proxy: ScrollViewProxy) -> some View {
        Button {
            resumeFollowing(proxy: proxy)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "music.note")
                    .font(.system(size: 13, weight: .semibold))

                Text(Localized.lyricsBackToCurrent)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule().stroke(accent.opacity(0.5), lineWidth: 1)
                    )
            )
            .shadow(color: accent.opacity(0.35), radius: 18, y: 6)
        }
        .buttonStyle(PressableButtonStyle(pressedScale: 0.96))
    }

    // MARK: Scroll coordination

    private func handle(_ phase: ScrollPhase) {
        switch phase {
        case .tracking:
            // A finger resting on the list may still turn out to be a tap on a
            // line, so hold auto-scroll without claiming the user is browsing.
            isTouching = true
            lastInteraction = Date()
        case .interacting, .decelerating:
            isTouching = true
            lastInteraction = Date()
            if !isBrowsing {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isBrowsing = true
                }
            }
        case .idle:
            isTouching = false
            if isBrowsing { lastInteraction = Date() }
        case .animating:
            break
        @unknown default:
            isTouching = false
        }
    }

    private func handleTap(_ row: LyricRow, proxy: ScrollViewProxy) {
        guard let onSeek else { return }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onSeek(row.start)

        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isBrowsing = false
        }
        // Jump to the tapped row rather than waiting for the next playback
        // tick to report the new position.
        scroll(toRowID: row.id, proxy: proxy, animated: true)
    }

    private func resumeFollowing(proxy: ScrollViewProxy) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isBrowsing = false
        }
        scroll(toRowAt: activeIndex, proxy: proxy, animated: true)
    }

    private func scroll(toRowAt index: Int?, proxy: ScrollViewProxy, animated: Bool) {
        guard let index, rows.indices.contains(index) else { return }
        scroll(toRowID: rows[index].id, proxy: proxy, animated: animated)
    }

    // MARK: Cascade

    /// Only the ordinary case - playback stepping forward by a line or two -
    /// cascades. Seeks, jumps back and Reduce Motion use a plain scroll.
    private func canCascade(from old: Int, to new: Int) -> Bool {
        guard !reduceMotion, new > old, new - old <= 2 else { return false }
        return (old..<new).allSatisfy { rowHeights[$0] != nil }
    }

    private func cascade(from old: Int, to new: Int, proxy: ScrollViewProxy) {
        let travel = (old..<new).reduce(CGFloat(0)) { $0 + (rowHeights[$1] ?? 0) }
        guard travel > 0, rows.indices.contains(new) else {
            scroll(toRowAt: new, proxy: proxy, animated: true)
            return
        }

        // Move the list and pre-displace every row by the same amount in one
        // un-animated transaction, so nothing visibly changes yet...
        var jump = Transaction()
        jump.disablesAnimations = true
        withTransaction(jump) {
            proxy.scrollTo(rows[new].id, anchor: focusAnchor)
            cascadeShift = travel
        }
        // ...then release the rows; each springs home on its own delay.
        DispatchQueue.main.async {
            cascadeShift = 0
        }
    }

    /// Rows above the outgoing line go together; from there down each row
    /// starts a beat after the one above it, capped so the tail never lags.
    private func cascadeAnimation(for row: LyricRow) -> Animation? {
        guard !reduceMotion else { return nil }
        let leader = max((activeIndex ?? 0) - 1, 0)
        let step = Double(min(max(row.id - leader, 0), 7))
        return .spring(response: 0.62, dampingFraction: 0.86).delay(step * 0.045)
    }

    private func scroll(toRowID id: Int, proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(scrollAnimation) {
                proxy.scrollTo(id, anchor: focusAnchor)
            }
        } else {
            proxy.scrollTo(id, anchor: focusAnchor)
        }
    }
}

/// One lyric line, with the sung part lifted out of the rest of it.
///
/// LRC gives a start time per line and nothing finer, so there is no real word
/// timing to draw. Sweeping a brightness front across the line over its own
/// duration is the honest approximation: it is derived entirely from where the
/// line starts and where the next one does, and it turns the active line from
/// something that is merely brighter into something visibly being sung now.
private struct LyricLineText: View {
    let text: String
    let font: Font
    /// 0...1 through the line, or nil when this line is not the active one.
    /// Supplied per display frame by the caller, so it is not animated here.
    let sweep: Double?

    var body: some View {
        Text(text)
            .font(font)
            .foregroundColor(.white)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            // Applied even when the line is inactive, rather than branching on
            // `sweep`: an if/else here would give the two states different view
            // identities, so a line would be rebuilt at the moment it became
            // active - visibly, mid-animation. An inactive line costs the
            // renderer a single plain pass.
            .textRenderer(LyricSweepRenderer(progress: sweep ?? 1, isActive: sweep != nil))
    }
}

/// Sweeps the brightness front across a laid-out line in reading order.
///
/// A mask over the whole text block cannot do this. Once a lyric wraps, the
/// block is two stacked lines, and a single left-to-right band lights the right
/// half of both at the same moment - the end of the phrase brightening before
/// its middle. `TextRenderer` hands us the actual laid-out lines, so the sweep
/// can be spent along one line before it starts on the next, which is the order
/// the words are sung in.
///
private struct LyricSweepRenderer: TextRenderer {
    var progress: Double
    /// false for a line that is not being sung: draw it plainly.
    var isActive: Bool
    /// How dark the not-yet-sung remainder sits behind the front.
    var dimOpacity: Double = 0.32

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let lines = Array(layout)
        guard !lines.isEmpty else { return }

        guard isActive else {
            for line in lines { context.draw(line) }
            return
        }

        // Progress is spent against total typographic width, so a long first
        // line takes proportionally longer to fill than a short second one -
        // which is what makes it track the singing rather than the line count.
        // Deliberately the rect's width, the same measure the clip below is
        // built from. `typographicBounds.width` can disagree with it over
        // trailing whitespace, and a spend measured against one while clipping
        // against the other drifts a little further out of step on every line.
        let widths = lines.map(\.typographicBounds.rect.width)
        let total = widths.reduce(0, +)
        guard total > 0 else {
            for line in lines { context.draw(line) }
            return
        }

        let target = total * min(max(progress, 0), 1)
        var consumed: CGFloat = 0

        for (index, line) in lines.enumerated() {
            let width = widths[index]
            let bounds = line.typographicBounds.rect

            var unsung = context
            unsung.opacity = dimOpacity
            unsung.draw(line)

            let filled = min(max(target - consumed, 0), width)
            consumed += width
            guard filled > 0 else { continue }

            var sung = context
            // Generous vertical bleed: the clip only ever needs to cut
            // horizontally, and ascenders and descenders reach outside the
            // typographic rect.
            let bandY = bounds.minY - bounds.height
            let bandHeight = bounds.height * 3
            if filled >= width {
                sung.clip(to: Path(CGRect(x: bounds.minX - 20, y: bandY, width: width + 40, height: bandHeight)))
            } else {
                // A feathered front rather than a hard cut: the light bleeds
                // into the next letters the way a voice carries into a word.
                let feather = min(bounds.height * 0.9, 28)
                let solidEnd = bounds.minX + max(filled - feather / 2, 0)
                sung.clipToLayer { layer in
                    layer.fill(
                        Path(CGRect(x: bounds.minX - 20, y: bandY, width: solidEnd - bounds.minX + 20, height: bandHeight)),
                        with: .color(.black)
                    )
                    layer.fill(
                        Path(CGRect(x: solidEnd, y: bandY, width: feather, height: bandHeight)),
                        with: .linearGradient(
                            Gradient(colors: [.black, .clear]),
                            startPoint: CGPoint(x: solidEnd, y: 0),
                            endPoint: CGPoint(x: solidEnd + feather, y: 0)
                        )
                    )
                }
            }
            sung.draw(line)
        }
    }
}

/// Three dots that fill across an instrumental break, so a long interlude
/// reads as progress rather than a stalled screen.
private struct LyricsBreakIndicator: View {
    let progress: Double
    let isActive: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 13) {
            ForEach(0..<3, id: \.self) { index in
                let fill = min(max((progress - Double(index) / 3) * 3, 0), 1)

                Circle()
                    .fill(
                        isActive
                        ? Color.white.opacity(0.32 + 0.68 * fill)
                        : Color.white.opacity(0.5)
                    )
                    .frame(width: 12, height: 12)
                    .scaleEffect(isActive ? 0.8 + 0.4 * fill : 0.62)
                    .shadow(color: accent.opacity(isActive ? 0.5 * fill : 0), radius: 12)
            }
        }
        .animation(.linear(duration: 0.25), value: progress)
        .frame(height: 26)
    }
}

// MARK: - Status Card

/// Loading, instrumental and not-found all share one glass card so the three
/// states stay visually identical and only their contents differ.
private struct LyricsStatusCard: View {
    enum Icon {
        case symbol(String)
        case progress
    }

    let icon: Icon
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    /// Plain type on the artwork backdrop: no card and no accent glow
    /// competing with the artwork colours.
    var body: some View {
        VStack(spacing: 14) {
            Group {
                switch icon {
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                case .progress:
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
            }
            .frame(height: 44)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .adaptiveGlassButtonStyle()
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }
}

/// Lets the user override the automatic match with any record lrclib holds.
///
/// Duration is shown for every row because it is usually the thing that tells
/// two records of the same song apart - a radio edit from an album cut, a live
/// take from the studio one - and it is the field the automatic scorer weighs
/// most heavily when it gets the choice wrong.
private struct LyricsVersionPicker: View {
    let accent: Color
    let load: () async -> [LyricsManager.LyricsCandidate]
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [LyricsManager.LyricsCandidate]?

    var body: some View {
        NavigationStack {
            Group {
                if let candidates {
                    if candidates.isEmpty {
                        ContentUnavailableView(
                            Localized.lyricsUnavailable,
                            systemImage: "text.badge.xmark",
                            description: Text(Localized.lyricsUnavailableMessage)
                        )
                    } else {
                        List(candidates) { candidate in
                            Button {
                                onSelect(candidate.id)
                            } label: {
                                row(for: candidate)
                            }
                            .buttonStyle(.plain)
                        }
                        .listStyle(.plain)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(Localized.lyricsChooseVersion)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Localized.cancel) { dismiss() }
                }
            }
        }
        .task {
            candidates = await load()
        }
    }

    private func row(for candidate: LyricsManager.LyricsCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(candidate.trackName)
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(1)

            Text(candidate.artistName)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            HStack(spacing: 8) {
                if !candidate.albumName.isEmpty {
                    Text(candidate.albumName)
                        .lineLimit(1)
                }

                Text(durationText(candidate.duration))

                if candidate.isInstrumental {
                    badge(Localized.lyricsInstrumental)
                } else if candidate.hasSyncedLyrics {
                    badge(Localized.lyricsSynced)
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().stroke(accent.opacity(0.5), lineWidth: 1))
    }

    private func durationText(_ duration: TimeInterval) -> String {
        guard duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Preview

#Preview {
    LyricsView(
        lyrics: Lyrics(
            plainLyrics: "Sample lyrics\nLine 2\nLine 3",
            syncedLyrics: [
                LyricsLine(timestamp: 12, text: "Sample lyrics"),
                LyricsLine(timestamp: 17, text: "Line 2"),
                LyricsLine(timestamp: 22, text: "Line 3"),
                LyricsLine(timestamp: 45, text: "After the solo")
            ],
            isInstrumental: false,
            source: .lrclib
        ),
        currentTime: 18.0,
        isLoading: false,
        isPlaying: true,
        onSeek: { _ in }
    )
    .padding(20)
    .background(Color.indigo.gradient)
}
