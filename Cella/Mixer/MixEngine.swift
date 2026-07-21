//
//  MixEngine.swift
//  Cella
//
//  Directed compatibility scoring and intelligent track ordering for the automix queue.
//  Prioritizes key, outro-to-intro energy, tempo, vocal overlap, and spectral fit.
//

import Foundation

enum MixEngine {
    /// Weights for compatibility scoring components.
    private static let tempoWeight: Double = 0.22
    private static let keyWeight: Double = 0.30
    private static let energyWeight: Double = 0.26
    private static let spectralWeight: Double = 0.10
    private static let vocalWeight: Double = 0.12

    // MARK: - Compatibility Scoring

    /// Scores how compatible two tracks are for a smooth directed transition (0.0–1.0).
    static func scoreCompatibility(a: TrackAnalysis, b: TrackAnalysis) -> Double {
        let tempoScore = tempoCompatibility(a: a, b: b)
        let keyScore = keyCompatibility(a: a, b: b)
        let energyScore = transitionEnergyCompatibility(outgoing: a, incoming: b)
        let spectralScore = spectralCompatibility(a: a, b: b)
        let vocalScore = vocalCompatibility(a: a, b: b)

        let rawScore = (tempoScore * tempoWeight) + (keyScore * keyWeight) +
               (energyScore * energyWeight) + (spectralScore * spectralWeight) +
               (vocalScore * vocalWeight)

        return applyHardCaps(
            score: rawScore,
            keyScore: keyScore,
            energyScore: energyScore,
            tempoScore: tempoScore,
            vocalScore: vocalScore
        )
    }

    // MARK: - Vocal Compatibility

    /// Avoids vocal collisions by penalizing pairs where both tracks have strong
    /// vocal activity in their crossfade regions.
    private static func vocalCompatibility(a: TrackAnalysis, b: TrackAnalysis) -> Double {
        let aVocal = a.hasVocals
        let bVocal = b.hasVocals

        if !aVocal && !bVocal { return 1.0 }
        if aVocal != bVocal { return 0.9 }

        // Both have vocals — check crossfade-region overlap
        let aEndActivity = Array(a.vocalActivity.suffix(20))
        let bStartActivity = Array(b.vocalActivity.prefix(20))

        let aAvg = aEndActivity.isEmpty ? Float(0) : aEndActivity.reduce(0, +) / Float(aEndActivity.count)
        let bAvg = bStartActivity.isEmpty ? Float(0) : bStartActivity.reduce(0, +) / Float(bStartActivity.count)

        let overlap = aAvg * bAvg
        return max(0.4, 1.0 - Double(overlap))
    }

    // MARK: - Tempo Compatibility

    /// BPM compatibility with harmonic ratio detection (2:1, 3:2, 4:3).
    private static func tempoCompatibility(a: TrackAnalysis, b: TrackAnalysis) -> Double {
        guard let bpmA = a.bpm, let bpmB = b.bpm else { return 0.5 }

        // Direct match
        let diff = abs(bpmA - bpmB)
        let avgBpm = (bpmA + bpmB) / 2.0
        let percentDiff = diff / avgBpm

        if percentDiff < 0.02 { return 1.0 } // Near-perfect match
        if percentDiff < 0.05 { return 0.95 }
        if percentDiff < 0.10 { return 0.85 }

        // Check harmonic tempo ratios
        let ratio = bpmA / bpmB
        let harmonicScore = harmonicTempoScore(ratio: ratio)
        if harmonicScore > 0.8 { return harmonicScore }

        // Falloff for incompatible tempos
        if percentDiff >= 0.20 { return 0.0 }
        return 0.5 * (1.0 - (percentDiff - 0.10) / 0.10)
    }

    /// Scores how well two tempos relate via common harmonic ratios.
    /// Returns 0.0–1.0 where higher = more compatible.
    private static func harmonicTempoScore(ratio: Double) -> Double {
        // Common harmonic ratios in music
        let harmonicRatios: [(ratio: Double, score: Double)] = [
            (1.0, 1.0),    // Same tempo
            (2.0, 0.9),    // 2:1 (half/double time)
            (0.5, 0.9),
            (1.5, 0.85),   // 3:2
            (2.0 / 3.0, 0.85),
            (4.0 / 3.0, 0.8), // 4:3
            (3.0 / 4.0, 0.8),
            (1.25, 0.75),  // 5:4
            (4.0 / 5.0, 0.75),
            (1.333, 0.7),  // 4:3 (approx)
            (3.0 / 4.0, 0.7),
        ]

        var bestScore: Double = 0
        for (hr, score) in harmonicRatios {
            let diff = abs(ratio - hr)
            if diff < 0.02 {
                bestScore = max(bestScore, score)
            } else if diff < 0.05 {
                bestScore = max(bestScore, score * 0.8)
            }
        }

        return bestScore
    }

    // MARK: - Key Compatibility

    /// Key compatibility using circle of fifths + relative major/minor recognition.
    private static func keyCompatibility(a: TrackAnalysis, b: TrackAnalysis) -> Double {
        guard let keyA = a.keySignature, let keyB = b.keySignature else { return 0.5 }

        // Check semitone distance (circle of fifths aware)
        let semitoneDist = keyA.semitoneDistance(to: keyB)
        let camelotDist = keyA.camelotDistance(to: keyB)

        // Same key = perfect
        if semitoneDist == 0 { return 1.0 }

        // Adjacent on Camelot wheel (compatible keys)
        if camelotDist <= 1 {
            // Check if they're relative major/minor (very harmonic)
            if isRelativeMajorMinor(keyA, keyB) {
                return 0.98
            }
            return 0.9
        }

        // Within 2 semitones (close keys)
        if semitoneDist <= 2 {
            return 0.85
        }

        // Camelot distance scoring
        switch camelotDist {
        case 2: return 0.7
        case 3: return 0.5
        case 4: return 0.3
        default: return 0.1
        }
    }

    /// Checks if two keys are relative major/minor pairs (e.g., C major / A minor).
    private static func isRelativeMajorMinor(_ a: TrackAnalysis.KeySignature, _ b: TrackAnalysis.KeySignature) -> Bool {
        // Relative major/minor share the same key signature
        // e.g., C major and A minor are relative pairs
        let relativePairs: [(major: String, minor: String)] = [
            ("C", "Am"), ("G", "Em"), ("D", "Bm"), ("A", "F#m"),
            ("E", "C#m"), ("B", "G#m"), ("F#", "D#m"), ("Db", "Bbm"),
            ("Ab", "Fm"), ("Eb", "Cm"), ("Bb", "Gm"), ("F", "Dm")
        ]

        for (major, minor) in relativePairs {
            let aIsMajor = a.mode.lowercased() == "major" && a.tonic == major
            let bIsMinor = b.mode.lowercased() == "minor" && b.tonic == minor
            let aIsMinor = a.mode.lowercased() == "minor" && a.tonic == minor
            let bIsMajor = b.mode.lowercased() == "major" && b.tonic == major

            if (aIsMajor && bIsMinor) || (aIsMinor && bIsMajor) {
                return true
            }
        }

        return false
    }

    // MARK: - Energy Compatibility

    /// Energy compatibility: similar energy levels + complementary energy flow.
    private static func energyCompatibility(a: TrackAnalysis, b: TrackAnalysis) -> Double {
        let energyA = averageEnergy(a.energyProfile)
        let energyB = averageEnergy(b.energyProfile)

        guard energyA > 0 || energyB > 0 else { return 0.5 }

        let maxEnergy = max(energyA, energyB)
        let minEnergy = min(energyA, energyB)
        let ratio = minEnergy / maxEnergy

        // Slight preference for energy builds (A→B where B is slightly louder)
        let energyDelta = energyB - energyA
        let buildBonus: Double
        if energyDelta > 0 && energyDelta < 0.15 {
            buildBonus = 0.05 // Small energy build is nice
        } else if energyDelta < -0.2 {
            buildBonus = -0.05 // Big energy drop is less ideal
        } else {
            buildBonus = 0
        }

        return min(1.0, max(0.0, ratio + buildBonus))
    }

    /// Transition energy compatibility compares the outgoing ending to the incoming beginning.
    private static func transitionEnergyCompatibility(outgoing: TrackAnalysis, incoming: TrackAnalysis) -> Double {
        let outEnd = segmentAverage(outgoing.energyProfile, region: .end, count: 24)
        let inStart = segmentAverage(incoming.energyProfile, region: .start, count: 24)

        guard outEnd > 0 || inStart > 0 else { return energyCompatibility(a: outgoing, b: incoming) }

        let levelDiff = abs(outEnd - inStart)
        let levelScore = max(0.0, 1.0 - Double(levelDiff) * 3.0)

        let outSlope = segmentSlope(outgoing.energyProfile, region: .end, count: 24)
        let inSlope = segmentSlope(incoming.energyProfile, region: .start, count: 24)
        let slopeDelta = abs(Double(outSlope - inSlope))
        let slopeScore = max(0.0, 1.0 - slopeDelta * 4.0)

        let wholeTrackScore = energyCompatibility(a: outgoing, b: incoming)
        return min(1.0, max(0.0, levelScore * 0.58 + slopeScore * 0.24 + wholeTrackScore * 0.18))
    }

    private enum SegmentRegion {
        case start
        case end
    }

    private static func segmentAverage(_ values: [Float], region: SegmentRegion, count: Int) -> Float {
        let segment = segment(values, region: region, count: count)
        guard !segment.isEmpty else { return 0 }
        return segment.reduce(0, +) / Float(segment.count)
    }

    private static func segmentSlope(_ values: [Float], region: SegmentRegion, count: Int) -> Float {
        let segment = segment(values, region: region, count: count)
        guard segment.count >= 2 else { return 0 }

        let midpoint = segment.count / 2
        let first = Array(segment[..<midpoint])
        let second = Array(segment[midpoint...])
        let firstAvg = first.reduce(0, +) / Float(first.count)
        let secondAvg = second.reduce(0, +) / Float(second.count)
        return secondAvg - firstAvg
    }

    private static func segment(_ values: [Float], region: SegmentRegion, count: Int) -> [Float] {
        guard !values.isEmpty else { return [] }
        let length = min(count, values.count)

        switch region {
        case .start:
            return Array(values.prefix(length))
        case .end:
            return Array(values.suffix(length))
        }
    }

    private static func applyHardCaps(
        score: Double,
        keyScore: Double,
        energyScore: Double,
        tempoScore: Double,
        vocalScore: Double
    ) -> Double {
        var cappedScore = score

        if keyScore < 0.30 {
            cappedScore = min(cappedScore, 0.58)
        } else if keyScore < 0.50 {
            cappedScore = min(cappedScore, 0.70)
        }

        if energyScore < 0.35 {
            cappedScore = min(cappedScore, 0.62)
        }

        if tempoScore < 0.35 {
            cappedScore = min(cappedScore, 0.68)
        }

        if vocalScore < 0.55 {
            cappedScore = min(cappedScore, 0.72)
        }

        return min(1.0, max(0.0, cappedScore))
    }

    // MARK: - Spectral Compatibility

    /// Spectral compatibility: matching tonal characteristics (brightness, noisiness).
    private static func spectralCompatibility(a: TrackAnalysis, b: TrackAnalysis) -> Double {
        // Centroid similarity (brightness)
        let centroidDiff = abs(a.spectralCentroid - b.spectralCentroid)
        let centroidScore: Double
        if centroidDiff < 200 {
            centroidScore = 1.0
        } else if centroidDiff < 500 {
            centroidScore = 0.8
        } else if centroidDiff < 1000 {
            centroidScore = 0.5
        } else {
            centroidScore = 0.2
        }

        // Flatness similarity (tonal vs noisy)
        let flatnessDiff = abs(a.spectralFlatness - b.spectralFlatness)
        let flatnessScore: Double
        if flatnessDiff < 0.1 {
            flatnessScore = 1.0
        } else if flatnessDiff < 0.2 {
            flatnessScore = 0.8
        } else {
            flatnessScore = 0.5
        }

        return (centroidScore * 0.6) + (flatnessScore * 0.4)
    }

    /// Average energy from an RMS profile.
    private static func averageEnergy(_ profile: [Float]) -> Double {
        guard !profile.isEmpty else { return 0 }
        let sum = profile.reduce(0, +)
        return Double(sum) / Double(profile.count)
    }

    // MARK: - Track Ordering

    /// Builds an optimally ordered mix queue from a set of analyzed tracks.
    /// Uses nearest-insertion TSP heuristic for better global ordering.
    static func buildMixQueue(tracks: [TrackAsset], startingWith startURL: URL? = nil) -> MixQueue {
        let analyzedTracks = tracks.filter { $0.analysis != nil }
        guard !analyzedTracks.isEmpty else {
            print("[MixEngine] Warning: no analyzed tracks — returning empty queue")
            return MixQueue(tracks: [], transitions: [])
        }
        guard analyzedTracks.count > 1 else {
            return MixQueue(
                tracks: analyzedTracks,
                transitions: [nil] + Array(repeating: nil, count: max(0, analyzedTracks.count - 1))
            )
        }

        let n = analyzedTracks.count

        // Build NxN compatibility matrix
        var compatibilityMatrix = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)

        for i in 0..<n {
            for j in 0..<n where i != j {
                guard let analysisA = analyzedTracks[i].analysis,
                      let analysisB = analyzedTracks[j].analysis else { continue }
                compatibilityMatrix[i][j] = scoreCompatibility(a: analysisA, b: analysisB)
            }
        }

        let orderedIndices: [Int]
        if let startURL,
           let startIndex = analyzedTracks.firstIndex(where: { $0.url == startURL }) {
            orderedIndices = anchoredForwardOrdering(
                matrix: compatibilityMatrix,
                count: n,
                startIndex: startIndex
            )
        } else {
            // Nearest-insertion TSP heuristic
            var globalIndices = nearestInsertionOrdering(matrix: compatibilityMatrix, count: n)

            // 2-opt improvement pass
            globalIndices = twoOptImprove(indices: globalIndices, matrix: compatibilityMatrix)
            orderedIndices = globalIndices
        }

        // Build ordered arrays
        let orderedTracks = orderedIndices.map { analyzedTracks[$0] }

        // Create transition logs
        var transitions: [TransitionLog?] = [nil]
        for i in 0..<(orderedTracks.count - 1) {
            let from = orderedTracks[i]
            let to = orderedTracks[i + 1]
            transitions.append(TransitionLog(
                fromTrack: from.url,
                toTrack: to.url,
                crossfadeDuration: computeCrossfadeDuration(from: from, to: to)
            ))
        }

        return MixQueue(
            tracks: orderedTracks,
            transitions: transitions
        )
    }

    // MARK: - Anchored Forward Ordering

    /// Builds the queue from the currently playing track forward.
    /// This favors the very next transition instead of a global path edge that may wrap badly.
    private static func anchoredForwardOrdering(matrix: [[Double]], count: Int, startIndex: Int) -> [Int] {
        guard count > 0 else { return [] }

        var ordered = [startIndex]
        var remaining = Set(0..<count)
        remaining.remove(startIndex)

        while let current = ordered.last, !remaining.isEmpty {
            let next = remaining.max { lhs, rhs in
                anchoredCandidateScore(current: current, candidate: lhs, remaining: remaining, matrix: matrix) <
                anchoredCandidateScore(current: current, candidate: rhs, remaining: remaining, matrix: matrix)
            }

            guard let next else { break }
            ordered.append(next)
            remaining.remove(next)
        }

        return ordered
    }

    private static func anchoredCandidateScore(
        current: Int,
        candidate: Int,
        remaining: Set<Int>,
        matrix: [[Double]]
    ) -> Double {
        let immediate = matrix[current][candidate]
        let futureBest = remaining
            .filter { $0 != candidate }
            .map { matrix[candidate][$0] }
            .max() ?? 0

        return immediate * 0.82 + futureBest * 0.18
    }

    // MARK: - TSP Heuristic (Nearest Insertion)

    /// Nearest-insertion algorithm for TSP approximation — O(n²).
    /// Finds the nearest unvisited node to the current tour, then inserts it
    /// at the position that maximizes local compatibility.
    private static func nearestInsertionOrdering(matrix: [[Double]], count: Int) -> [Int] {
        guard count > 0 else { return [] }

        var tour = [0]
        var inTour = Set<Int>([0])

        while tour.count < count {
            // Step 1: Find the nearest unvisited node to any node in the tour.
            var bestNode = -1
            var bestEdgeScore = -Double.infinity

            for candidate in 0..<count where !inTour.contains(candidate) {
                // Best edge from candidate to any node already in tour
                var bestToTour = -Double.infinity
                for tourNode in tour {
                    let score = matrix[candidate][tourNode]
                    if score > bestToTour {
                        bestToTour = score
                    }
                }
                if bestToTour > bestEdgeScore {
                    bestEdgeScore = bestToTour
                    bestNode = candidate
                }
            }

            guard bestNode >= 0 else { break }

            // Step 2: Insert at the position that maximizes local compatibility.
            var bestInsertIdx = 0
            var bestInsertDelta = -Double.infinity

            for insertPos in 0...tour.count {
                let delta = insertionDelta(
                    matrix: matrix, tour: tour,
                    candidate: bestNode, at: insertPos
                )
                if delta > bestInsertDelta {
                    bestInsertDelta = delta
                    bestInsertIdx = insertPos
                }
            }

            tour.insert(bestNode, at: bestInsertIdx)
            inTour.insert(bestNode)
        }

        return tour
    }

    /// O(1) score delta for inserting a candidate at a given position.
    /// Positive = adding this edge improves total compatibility.
    private static func insertionDelta(matrix: [[Double]], tour: [Int], candidate: Int, at pos: Int) -> Double {
        let prev = pos > 0 ? tour[pos - 1] : -1
        let next = pos < tour.count ? tour[pos] : -1

        var delta = 0.0
        // Gain from new edges to candidate
        if prev >= 0 { delta += matrix[prev][candidate] }
        if next >= 0 { delta += matrix[candidate][next] }
        // Loss from broken edge (if both neighbors exist)
        if prev >= 0, next >= 0 { delta -= matrix[prev][next] }

        return delta
    }

    // MARK: - 2-opt Improvement

    /// 2-opt local search improvement for TSP.
    /// Repeatedly reverses sub-tours to increase total compatibility. Linear (not cyclic).
    private static func twoOptImprove(indices: [Int], matrix: [[Double]]) -> [Int] {
        var result = indices
        let n = result.count
        guard n > 3 else { return result }

        var improved = true
        while improved {
            improved = false

            for i in 0..<(n - 1) {
                for j in (i + 2)..<n {
                    // Current edges: (i, i+1) and (j, j+1) if j+1 < n
                    // Alternative: (i, j) and (i+1, j+1) with reversed segment
                    let currentScore = matrix[result[i]][result[i + 1]] +
                        (j + 1 < n ? matrix[result[j]][result[j + 1]] : 0)
                    let newScore = matrix[result[i]][result[j]] +
                        (j + 1 < n ? matrix[result[i + 1]][result[j + 1]] : 0)

                    if newScore > currentScore + 0.01 {
                        let segment = Array(result[(i + 1)...j].reversed())
                        result.replaceSubrange((i + 1)...j, with: segment)
                        improved = true
                    }
                }
            }
        }

        return result
    }

    /// Computes appropriate crossfade duration based on track properties.
    private static func computeCrossfadeDuration(from: TrackAsset, to: TrackAsset) -> Double {
        guard let fromAnalysis = from.analysis,
              let toAnalysis = to.analysis else {
            return 8.0
        }

        let baseDuration = 8.0

        // Shorter crossfade if tracks are very different in energy
        let energyDiff = abs(
            averageEnergy(fromAnalysis.energyProfile) -
            averageEnergy(toAnalysis.energyProfile)
        )

        if energyDiff > 0.3 {
            return baseDuration * 0.7
        }

        // Longer crossfade for very compatible tracks
        let compat = scoreCompatibility(a: fromAnalysis, b: toAnalysis)
        if compat > 0.8 {
            return baseDuration * 1.2
        }

        return baseDuration
    }
}
