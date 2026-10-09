//
//  LyricsLiveActivityController.swift
//  Cosmos Music Player
//
//  Drives the lyrics Live Activity: the current line in the Dynamic Island
//  and on the Lock Screen.
//

import ActivityKit
import Combine
import UIKit

@MainActor
final class LyricsLiveActivityController {
    static let shared = LyricsLiveActivityController()

    private let engine = PlayerEngine.shared
    private var cancellables = Set<AnyCancellable>()
    private var activity: Activity<LyricsActivityAttributes>?
    private var isEnabled = DeleteSettings.load().showLyricsInDynamicIsland

    /// Timed lines of the current track, in order, and who it is by; loaded
    /// once per track.
    private var lines: [(time: TimeInterval, text: String)] = []
    private var artistName = ""
    private var lyricsTask: Task<Void, Never>?
    /// Last state sent, so the activity is only updated when a line, the
    /// track or play/pause actually changes - not on every position tick.
    private var lastState: LyricsActivityAttributes.ContentState?

    private init() {}

    func start() {
        guard cancellables.isEmpty else { return }

        // Activities outlive the app process; one left by a previous run
        // would keep showing a stale line.
        for leftover in Activity<LyricsActivityAttributes>.activities {
            ActivityHandle(activity: leftover).end()
        }

        // `@Published` emits before the property changes, so hop to the next
        // main-queue turn and read the engine's settled state.
        engine.$currentTrack
            .map { $0?.stableId }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.trackDidChange() }
            .store(in: &cancellables)

        engine.$isPlaying
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // 4 Hz in the foreground; the engine's background monitor keeps it
        // moving while the app is in the background.
        engine.progress.$playbackTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .cosmosSettingsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let enabled = DeleteSettings.load().showLyricsInDynamicIsland
                guard enabled != self.isEnabled else { return }
                self.isEnabled = enabled
                self.trackDidChange()
            }
            .store(in: &cancellables)

        // An activity can only be started from the foreground; try again when
        // the app comes back if playback began while it was away.
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        trackDidChange()
    }

    // MARK: - State

    private func trackDidChange() {
        lyricsTask?.cancel()
        lines = []
        artistName = ""

        guard isEnabled, let track = engine.currentTrack else {
            refresh()
            return
        }

        artistName = (try? DatabaseManager.shared.getArtistDisplayName(
            forTrackStableId: track.stableId,
            fallbackArtistId: track.artistId
        )) ?? ""
        refresh()

        let trackId = track.stableId
        lyricsTask = Task { [weak self] in
            let lyrics = await LyricsManager.shared.getLyrics(for: track)
            guard let self, !Task.isCancelled, self.engine.currentTrack?.stableId == trackId else { return }
            self.lines = (lyrics?.syncedLyrics ?? [])
                .compactMap { line in line.timestamp.map { (time: $0, text: line.text) } }
                .sorted { $0.time < $1.time }
            self.refresh()
        }
    }

    private func refresh() {
        guard isEnabled,
              let track = engine.currentTrack,
              engine.playbackState != .stopped else {
            endActivity()
            return
        }

        // A hair early, so the island changes with the voice rather than
        // just after it.
        let time = engine.currentPlaybackPosition() + 0.15
        let index = lines.lastIndex { $0.time <= time }
        let line = index.map { lines[$0].text } ?? ""
        let nextLine: String
        if let index {
            nextLine = index + 1 < lines.count ? lines[index + 1].text : ""
        } else {
            nextLine = lines.first?.text ?? ""
        }

        let state = LyricsActivityAttributes.ContentState(
            trackId: track.stableId,
            title: track.title,
            artist: artistName,
            line: line.trimmingCharacters(in: .whitespaces),
            nextLine: nextLine.trimmingCharacters(in: .whitespaces),
            isPlaying: engine.isPlaying,
            hasLyrics: !lines.isEmpty
        )
        guard state != lastState else { return }

        if let activity {
            lastState = state
            ActivityHandle(activity: activity).update(state)
        } else if engine.isPlaying,
                  UIApplication.shared.applicationState == .active,
                  ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                activity = try Activity.request(
                    attributes: LyricsActivityAttributes(),
                    content: ActivityContent(state: state, staleDate: nil)
                )
                lastState = state
            } catch {
                print("⚠️ Lyrics Live Activity could not start: \(error.localizedDescription)")
            }
        }
    }

    private func endActivity() {
        lastState = nil
        guard let activity else { return }
        self.activity = nil
        ActivityHandle(activity: activity).end()
    }
}

/// `Activity` is not marked `Sendable`, but ActivityKit synchronises it
/// internally and its async methods are meant to be called from anywhere.
private struct ActivityHandle: @unchecked Sendable {
    let activity: Activity<LyricsActivityAttributes>

    func update(_ state: LyricsActivityAttributes.ContentState) {
        Task.detached { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        Task.detached { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
