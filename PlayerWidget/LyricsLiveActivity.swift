//
//  LyricsLiveActivity.swift
//  PlayerWidget
//
//  The current lyric line in the Dynamic Island and on the Lock Screen.
//

import ActivityKit
import ImageIO
import SwiftUI
import WidgetKit

struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LyricsLockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityArtwork(size: 52, cornerRadius: 12)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PlaybackGlyph(isPlaying: state.isPlaying)
                        .font(.title3)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(state.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LyricLines(state: state, lineFont: .title3.weight(.bold), nextFont: .subheadline.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                }
            } compactLeading: {
                ActivityArtwork(size: 22, cornerRadius: 6)
            } compactTrailing: {
                CompactLine(state: state)
            } minimal: {
                ActivityArtwork(size: 22, cornerRadius: 11)
            }
            .keylineTint(.white)
        }
    }
}

// MARK: - Pieces

/// The cover written by the app for the widgets, from the shared App Group.
private struct ActivityArtwork: View {
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if let image = Self.thumbnail(maxPixelSize: size * 3) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.15)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }

    /// Live Activities run under a tight memory limit and drop images that
    /// are much larger than they are drawn, so decode straight to the size
    /// on screen instead of loading the full widget cover.
    private static func thumbnail(maxPixelSize: CGFloat) -> UIImage? {
        guard let data = WidgetDataManager.shared.getArtwork(),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct PlaybackGlyph: View {
    let isPlaying: Bool

    var body: some View {
        Image(systemName: isPlaying ? "waveform" : "pause.fill")
            .foregroundStyle(.white)
            .symbolEffect(.variableColor.iterative, isActive: isPlaying)
            .contentTransition(.symbolEffect(.replace))
    }
}

/// The sung line in bold with the next one under it, pushed up as it changes.
private struct LyricLines: View {
    let state: LyricsActivityAttributes.ContentState
    let lineFont: Font
    let nextFont: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(primaryText)
                .font(lineFont)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id("line-\(state.trackId)-\(primaryText)")
                .transition(.push(from: .bottom))

            if state.hasLyrics, !state.nextLine.isEmpty {
                Text(state.nextLine)
                    .font(nextFont)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("next-\(state.trackId)-\(state.nextLine)")
                    .transition(.push(from: .bottom))
            }
        }
    }

    private var primaryText: String {
        guard state.hasLyrics else { return state.title }
        return state.line.isEmpty ? "♪" : state.line
    }
}

/// Room for a few words beside the island; the full line is one long-press
/// away in the expanded view.
private struct CompactLine: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        Group {
            if state.hasLyrics, !state.line.isEmpty, state.isPlaying {
                Text(state.line)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    // Shrinks before it truncates: most CJK lines and short
                    // English ones fit; the full line is in the expanded view
                    // and on the Lock Screen.
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: 140, alignment: .trailing)
                    .id(state.line)
                    .transition(.push(from: .bottom))
            } else {
                PlaybackGlyph(isPlaying: state.isPlaying)
                    .font(.caption.weight(.semibold))
            }
        }
    }
}

private struct LyricsLockScreenView: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ActivityArtwork(size: 40, cornerRadius: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(state.artist)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                PlaybackGlyph(isPlaying: state.isPlaying)
                    .font(.headline)
            }

            if state.hasLyrics {
                LyricLines(state: state, lineFont: .title3.weight(.bold), nextFont: .subheadline.weight(.semibold))
            }
        }
        .padding(16)
    }
}
