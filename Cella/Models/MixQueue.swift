//
//  MixQueue.swift
//  Cella
//
//  Ordered track list with crossfade transition metadata.
//

import Foundation

struct MixQueue {
    /// Tracks in play order.
    var tracks: [TrackAsset]

    /// Transition metadata between consecutive tracks.
    /// `transitions[i]` describes the crossfade from `tracks[i]` to `tracks[i+1]`.
    /// `transitions[0]` is always nil (no transition before the first track).
    var transitions: [TransitionLog?]

    /// Index of the currently playing track.
    var currentIndex: Int = 0

    /// The currently playing track, if any.
    var currentTrack: TrackAsset? {
        guard currentIndex >= 0, currentIndex < tracks.count else { return nil }
        return tracks[currentIndex]
    }

    /// The next track in the queue, wrapping to the first if there is more than one track.
    var nextTrack: TrackAsset? {
        guard tracks.count > 1 else { return nil }
        let nextIndex = (currentIndex + 1) % tracks.count
        return tracks[nextIndex]
    }

    /// Whether there are tracks in the queue.
    var isEmpty: Bool { tracks.isEmpty }

    /// Number of tracks in the queue.
    var count: Int { tracks.count }

    /// Move to the next track. Returns the new current track.
    @discardableResult
    mutating func advanceToNext() -> TrackAsset? {
        guard !tracks.isEmpty else { return nil }
        currentIndex = (currentIndex + 1) % tracks.count
        return currentTrack
    }

    /// Move to the previous track. Returns the new current track.
    @discardableResult
    mutating func advanceToPrevious() -> TrackAsset? {
        guard !tracks.isEmpty else { return nil }
        currentIndex = currentIndex > 0 ? currentIndex - 1 : tracks.count - 1
        return currentTrack
    }

    /// Jump to a specific index.
    @discardableResult
    mutating func jumpTo(index: Int) -> TrackAsset? {
        guard index >= 0, index < tracks.count else { return nil }
        currentIndex = index
        return currentTrack
    }
}
