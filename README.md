# Cella

> **macOS music player with AI-powered automix** — analyzes BPM, key, and vocals; orders tracks intelligently; crossfades with beat alignment and vocal preservation.

---

## ✨ Features

- **Smart automix** — TSP-optimized track ordering via compatibility scoring (key, energy, tempo, vocals, spectral)
- **Beat-aligned crossfades** — dynamic bar-quantized duration, gradual tempo sync, vocal-aware ducking
- **On-device analysis** — BPM (spfk-tempo), key signature (spfk-musical-analysis), LUFS loudness (spfk-loudness)
- **Vocal preservation** — detects vocal activity, avoids cutting phrases during transitions, adapts ducking strategy
- **9×5 dot matrix display** — mood-driven animations (5 moods × 4 frames), text scroller, pixel font
- **Procedural line visualizer** — Catmull-Rom path with energy-reactive trail + drifting stars
- **EPUB reader** — sentence-by-sentence with progress tracking, cover art, water reminder timer
- **8 audio profiles** — Flat, Bose, Sony, Apple, Sennheiser, Beats, JBL, AKG (EQ presets)
- **macOS native** — fullscreen, hidden title bar, keyboard shortcuts, remote command center
- **Dark / Light themes** — warm orange accent (#FF8038)

---

## 📸 Screenshots

| Cella Tab | Config Tab | Feeds Tab |
|-----------|------------|-----------|
| Dot matrix mood face + animated line visualizer | Folder import, queue, audio profile, analysis progress | EPUB library, mini reader, now playing, water reminder |

---

## 🏗 Architecture

```
CellaApp                     ← @main, fullscreen, hidden title bar
└── ContentView              ← root, tabs + keyboard shortcuts
    ├── TopTabBar            ← pill-style tab bar (scroll/drag switching)
    ├── FeedsView            ← EPUB reader + water reminder + mini player
    ├── CellaView            ← main player UI
    │   ├── EmotionScreenView  ← 21:9 dark container
    │   │   └── DotMatrixView  ← 9×5 dot grid renderer
    │   └── PlayerIndicatorView ← status text
    └── ConfigView           ← folder import + analysis progress
```

### Core Data Flow

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

---

## 🧩 Modules

### Models (`Models/`)

| File | Purpose |
|------|---------|
| `AppTab.swift` | 3-tab enum: feeds, cella, config |
| `AudioConfig.swift` | Global params: sample rate, crossfade duration, BPM/pitch limits, EQ, gain, LUFS target |
| `MixQueue.swift` | Ordered `[TrackAsset]` with `[TransitionLog?]`, index navigation |
| `PlayerState.swift` | State machine: idle → playing → paused → playing... + analyzing/loading/autoMix |
| `MusicMood.swift` | Mood enum derived from BPM, energy, key via adaptive thresholds |
| `TrackAnalysis.swift` | Full analysis: BPM, beat/bar timestamps, key (Camelot wheel), LUFS, structure, vocal activity |
| `TrackAsset.swift` | Single track: URL, analysis, status, filename parsing (Artist - Title) |
| `TransitionLog.swift` | Crossfade record: from/to URLs, duration, BPM/key/vocal adjustments |
| `BookAsset.swift` | EPUB metadata with reading progress |
| `AudioProfile.swift` | 8 EQ curves: Flat, Bose, Sony, Apple, Sennheiser, Beats, JBL, AKG |

### Audio Engine (`AudioEngine/MixAudioEngine.swift`)

Dual-player `AVAudioEngine` system (playerA + playerB):

```
playerA → timePitchA → eqA → mixer → spatialDelay → profileEq → hallReverb → peakLimiter → mainMixer
playerB → timePitchB → eqB →                                              ↗
```

- **Beat-aligned crossfade** — optimal bar boundary trigger via energy matching, phrase scoring, vocal end proximity, chorus protection
- **Gradual tempo sync** — smoothstep ramp of incoming track (2s glide), only slows incoming to match outgoing
- **Vocal-aware volume crossfade** — samples vocal activity at real playback position, proportional ducking with attack/release smoothing
- **EQ spectral blend** — optional low-pass outgoing + high-pass incoming sweep
- **Energy curve exponent** — adjusts crossfade curve shape based on energy ratio at transition point
- **Seek support** — re-reads from position, re-schedules buffer
- **Device change** — re-routes on `AVAudioEngineConfigurationChange`

### Analyzer (`Analyzer/TrackAnalyzer.swift`)

Swift actor for concurrent analysis:

- **BPM**: `spfk-tempo`
- **Key**: `spfk-musical-analysis` → tonic + mode
- **Loudness**: `spfk-loudness` → integrated LUFS, true peak
- **Downsampling**: mono 22kHz for memory efficiency (~13MB vs ~105MB for 5-min track)
- **Structure detection**: energy-based section segmentation (silence/intro/verse/chorus/bridge/outro)
- **Vocal detection**: 3-region centroid + ZCR + RMS voting
- **Per-window vocal activity**: Gaussian-weighted centroid + ZCR + energy scoring
- **Beat detection**: spectral flux onset-based, phase-locked to external BPM

### Crossfader (`Crossfader/Crossfader.swift`)

- **Dynamic duration**: bar-quantized, energy-difference adjusted, compatibility-scaled
- **Vocal strategy**: standard / duckIncoming / duckOutgoing / priorityOutgoing / priorityIncoming
- **Gain compensation**: LUFS → RMS → peak fallback chain
- **Vocal connection point**: first vocal onset / intro end / energy peak (capped at 20% or 45s)

### Mixer (`Mixer/MixEngine.swift`)

Compatibility scoring (0.0–1.0) with hard caps:

| Component | Weight | Factors |
|-----------|--------|---------|
| Key | 30% | Camelot wheel distance, relative major/minor, semitone distance |
| Energy | 26% | Transition energy (outgoing end → incoming start level + slope) |
| Tempo | 22% | Direct match + harmonic ratios (2:1, 3:2, 4:3) |
| Vocal | 12% | Penalizes both-tracks-vocal overlap in crossfade region |
| Spectral | 10% | Centroid + flatness similarity |

**Track ordering**: Nearest-insertion TSP heuristic + 2-opt improvement + anchored forward ordering

### Audio Utils (`AudioUtils/AudioHelpers.swift`)

Accelerate-based DSP:

- Normalization, equal-power fade (quintic smoothstep + cos/sin), soft limiter (tanh), compression (knee), gain limiting (RMS)
- Spectral features: single FFT pass → centroid, rolloff (85%), bandwidth, flatness — reusable `FFTSetup`
- RMS energy profile: vectorized mono mixdown, sliding window
- Vocal onset/offset: RMS threshold crossing
- Buffer mixing, extraction, silence creation, concatenation

### Display

| Component | What it does |
|-----------|--------------|
| `DotMatrixView` | 9×5 dot grid — moods, animations, text scrolling |
| `LineAnimationView` | Catmull-Rom trail + 4-point stars, energy-reactive speed |
| `PixelFont` | 3×5 bitmap font (A-Z, 0-9, punctuation) |
| `TextScroller` | Scrolls text across the 9×5 grid, phase-aware |
| `MatrixPatterns` | Smiley (normal/blink/sing1/sing2), skip, 4 mood animations |

### Player States

```
idle → playing → paused ↔ playing
     → analyzing(progress)
     → loading
     → autoMix
```

Each state drives the dot matrix display pattern and animation.

---

## 🎹 Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `Space` | Toggle play/pause |
| `←` | Skip backward (seek within 3s, else previous track) |
| `→` | Skip forward (crossfade to next track) |

---

## 📦 Dependencies

| Package | Purpose |
|---------|---------|
| `spfk-tempo` | BPM detection |
| `spfk-musical-analysis` | Key detection |
| `spfk-loudness` | LUFS measurement |
| `spfk-audiobase` | Shared audio types |
| `Accelerate` | System DSP framework (FFT, vDSP, BLAS) |
| `EPUBKit` | EPUB parsing |

---

## 🎵 Supported Audio Formats

`mp3`, `wav`, `m4a`, `flac`, `aac`, `caf`, `ogg`, `aif`

File naming: `Artist - Title.ext` → parsed into artist/title metadata.

---

## 🎨 Themes

| Token | Dark | Light |
|-------|------|-------|
| Background | `#0D0D0D` | `#FFFFFF` |
| Screen | `#231A16` | `#F5F0EB` |
| Tab bar | `#231A16` | `#F5F0EB` |
| Active dot | `#FF8038` | `#FF8038` |
| Inactive dot | `#3E2D24` | `#D4C5B8` |
| Text primary | `#D9D9D9` | `#2D1F17` |

---

## 📄 File Format

| Section | Example |
|---------|---------|
| Track file | `Artist - Title.mp3` |
| EPUB library | `~/Library/Application Support/CellaBooks/library.json` |
| Book covers | `~/Library/Application Support/CellaBooks/*_cover.*` |

---

## 🔧 Build

Open `Cella.xcodeproj` in Xcode 15+. SPM dependencies resolve automatically.

```bash
xed Cella.xcodeproj
```

---

## 📝 License

MIT
