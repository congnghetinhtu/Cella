# Cella

macOS SwiftUI music player with automix engine. Analyzes audio tracks (BPM, key, vocals, spectral features), arranges them in optimal order, and crossfades between them with beat alignment and vocal preservation.

---

## Architecture

```
CellaApp                     ← @main, fullscreen, hidden title bar
└── ContentView              ← root, tabs + keyboard shortcuts
    ├── TopTabBar            ← pill-style tab bar (scroll/drag switching)
    ├── ExploreView          ← placeholder
    ├── CellaView            ← main player UI
    │   ├── EmotionScreenView  ← 21:9 dark container
    │   │   └── DotMatrixView  ← 9×5 dot grid renderer
    │   └── PlayerIndicatorView ← status text
    └── ConfigView           ← folder import + analysis progress
```

## Core Data Flow

```
Folder Import (ConfigView)
    ↓
PlayerViewModel.importFolder()
    │
    ├── AudioHelpers.readAudio()   ← validate playability
    ├── audioEngine.loadTrack()    ← start playback immediately
    │
    └── TrackAnalyzer.analyzeAll() ← async concurrent analysis
            │
            ▼
        MixEngine.buildMixQueue()  ← TSP-based optimal ordering
            │
            ▼
        Crossfader.computeCrossfadeParams() → audioEngine.crossfadeToNext()
```

## Models (`Models/`)

| File | Purpose |
|------|---------|
| `AppTab.swift` | 3-tab enum: explore, cella, config |
| `AudioConfig.swift` | Global audio engine parameters (sample rate, crossfade duration, BPM/pitch limits, EQ, gain, LUFS target) |
| `MixQueue.swift` | Ordered `[TrackAsset]` with `[TransitionLog?]`, index navigation (next/prev/jump) |
| `PlayerState.swift` | State machine: idle → playing → paused → playing… + analyzing/loading/autoMix |
| `MusicMood.swift` | Mood enum (energeticHappy, energeticAngry, calmHappy, calmSad, neutral) derived from BPM, energy, key via adaptive thresholds |
| `TrackAnalysis.swift` | Full analysis struct: BPM, beat/bar timestamps, key signature (Camelot wheel), LUFS, structure sections, energy profile, vocal activity, spectral features, intro/outro regions, vocal boundaries |
| `TrackAsset.swift` | Single track: URL, analysis, status, filename parsing (artist - title) |
| `TransitionLog.swift` | Crossfade record: from/to URLs, duration, BPM/key/vocal adjustments |

## Audio Engine (`AudioEngine/MixAudioEngine.swift`)

Dual-player `AVAudioEngine` system (playerA + playerB) with:

- **Dual player routing**: each player → timePitch → EQ → mixerNode → mainMixer
- **Beat-aligned crossfade**: computes optimal bar boundary trigger time using energy matching, phrase scoring, vocal end proximity, chorus protection
- **Gradual tempo sync**: smoothstep ramp of incoming track from natural tempo to matched tempo (2s glide)
- **Vocal-aware volume crossfade**: samples vocal activity at real playback position, applies proportional ducking when both tracks have vocals, with attack/release smoothing
- **EQ spectral blend** (optional): low-pass outgoing + high-pass incoming sweep
- **Track end detection**: timer-based, fires `onTrackEnd` callback at computed beat boundary
- **Audio device change handling**: re-routes on `AVAudioEngineConfigurationChange`
- **Seek support**: re-reads file from position, re-schedules buffer

## Audio Utils (`AudioUtils/AudioHelpers.swift`)

Accelerate-based DSP:

- File I/O: `readAudio`, `writeAudio`
- Normalization, equal-power fade (quintic smoothstep + cos/sin), soft limiter (tanh), soft compression (knee), gain limiting (RMS-based)
- Spectral features: FFT → centroid, rolloff (85%), bandwidth, flatness — single reusable `FFTSetup`
- RMS energy profile: vectorized mono mixdown, sliding window
- Beat detection: spectral flux onset-based, phase-locked to external BPM
- Vocal boundary detection: RMS threshold crossing
- Buffer mixing, extraction, silence creation, concatenation

## Analyzer (`Analyzer/TrackAnalyzer.swift`)

Swift actor for concurrent analysis:

- **BPM**: `spfk-tempo` (`BpmAnalysis`)
- **Key**: `spfk-musical-analysis` (`MusicalKeyAnalysis`) → tonic + mode
- **Loudness**: `spfk-loudness` (`LoudnessAnalyzer`) → integrated LUFS, true peak
- **Downsampling**: mono 22kHz for memory efficiency (~13MB vs ~105MB for 5-min track)
- **Structure detection**: energy-based section segmentation (silence/intro/verse/chorus/bridge/outro)
- **Vocal detection**: 3-region centroid + ZCR + RMS voting
- **Per-window vocal activity**: Gaussian-weighted centroid + ZCR + energy scoring
- **Intro/outro**: inferred from structure sections

## Crossfader (`Crossfader/Crossfader.swift`)

Crossfade parameter computation:

- **Dynamic duration**: bar-quantized, energy-difference adjusted, compatibility-scaled
- **Vocal strategy**: standard / duckIncoming / duckOutgoing / priorityOutgoing / priorityIncoming — decides which track yields to the other during vocal overlap
- **Gain compensation**: LUFS-based loudness matching (falls back to RMS, then peak)
- **Vocal connection point**: finds first vocal onset / intro end / energy peak (capped at 20% of track or 45s)
- **Intro skip**: disabled (no song pieces cut per user request)

## Mixer (`Mixer/MixEngine.swift`)

Compatibility scoring and track ordering:

### Compatibility Scoring (0.0–1.0)

| Component | Weight | Factors |
|-----------|--------|---------|
| Key | 30% | Camelot wheel distance, relative major/minor, semitone distance |
| Energy | 26% | Transition energy compatibility (outgoing end → incoming start level + slope) |
| Tempo | 22% | Direct match + harmonic ratios (2:1, 3:2, 4:3) |
| Vocal | 12% | Penalizes both-tracks-vocal overlap in crossfade region |
| Spectral | 10% | Centroid + flatness similarity |

Hard caps: poor key ≤0.58 max, poor energy ≤0.62 max, poor tempo ≤0.68 max, poor vocal ≤0.72 max.

### Track Ordering

- Nearest-insertion TSP heuristic (tries all insertion positions)
- 2-opt improvement pass
- Anchored forward ordering when continuing from current track

## Theme (`Theme/AppColors.swift`)

Dark theme: background `#0D0D0D`, screen `#1A1A1A`, tab bar `#2A2A2A`, active dots `#D9D9D9`, inactive dots `#333333`.

## Utilities

| File | Purpose |
|------|---------|
| `MatrixPatterns.swift` | 9×5 dot patterns: smiley (normal/blink/sing1/sing2), skip forward/backward, analyzing, autoMix, loading, 4 mood animations (4 frames each) |
| `PixelFont.swift` | 3×5 bitmap font (A-Z, 0-9, punctuation) with glyph-to-column transposition |
| `TextScroller.swift` | Scrolls text columns across the 9×5 grid |

## SPM Dependencies

- `spfk-tempo` — BPM detection
- `spfk-musical-analysis` — key detection
- `spfk-loudness` — LUFS measurement
- `spfk-audiobase` — shared audio types
- **Accelerate** — system DSP framework (FFT, vDSP, BLAS)

## Player States

```
idle → playing → paused ↔ playing
     → analyzing(progress) — during analysis
     → loading — while building queue
     → autoMix — during crossfade transition
```

State influences dot matrix display pattern and animation.

## Keyboard Shortcuts

- **Space**: toggle play/pause
- **←** : skip backward (seek within 3s, else previous track)
- **→** : skip forward (crossfade to next track)

## Track File Parsing

Files named `Artist - Title.mp3` → parsed into artist/title. Supports: mp3, wav, m4a, flac, aac, caf, ogg, aif.
