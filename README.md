# Cella

macOS music player with OpenMix integration — Python-powered analysis and crossfade rendering streamed to a Swift/SwiftUI frontend.

---

## Architecture

```
┌───────────────────────────────────────────────────┐
│  Cella (Swift / SwiftUI)                          │
│                                                   │
│  PlayerViewModel                                  │
│  ├── importViaOpenMix()     ← folder import       │
│  ├── handleOpenMixStatus()  ← analysis progress   │
│  ├── handleOpenMixChunk()   ← audio playback      │
│  └── applyOpenMixAnalysis() ← BPM/key/energy sync │
│                                                   │
│  OpenMixBridge                                    │
│  ├── start() / stop()       ← subprocess lifecycle│
│  ├── analyze() / mix()      ← JSON commands       │
│  └── readAudioChunks()      ← named pipe reader   │
│                                                   │
│  StreamAudioEngine                                │
│  └── AVAudioEngine + AVAudioPlayerNode            │
│      3-chunk buffer-ahead, continuous playback    │
│                                                   │
│  MixAudioEngine (fallback only)                   │
│  └── Real-time crossfade if Python fails          │
└───────────────────────────────────────────────────┘
                      │
        subprocess + named pipe + stdin/stdout
                      │
┌───────────────────────────────────────────────────┐
│  OpenMix (Python)                                 │
│                                                   │
│  stream_server.py    stdin/stdout JSON + audio pipe│
│  analyzer.py         BPM, key, energy, vocals     │
│  crossfader.py       equal-power crossfade        │
│  mixer.py            track ordering, beat align   │
│  audio_utils.py      normalize, fade, soft limit  │
└───────────────────────────────────────────────────┘
```

## Features

- **OpenMix engine** — Python subprocess handles analysis and crossfade rendering; streams audio chunks via named pipe
- **Beat-aligned crossfades** — equal-power curves, phase alignment, zero-crossing boundary, vocal-aware ducking
- **On-device analysis** — BPM, key signature, energy profile, vocal detection, intro/outro detection
- **Analysis sync** — BPM, key, and energy profile flow back to Swift for line animation and mood system
- **Engine indicator HUD** — shows "OpenMix" (green) or "Real-Time" (orange) with rolling log
- **9x5 dot matrix display** — mood-driven animations, text scroller, pixel font
- **Procedural line visualizer** — Catmull-Rom path with energy-reactive trail
- **EPUB reader** — sentence-by-sentence with progress tracking, cover art, water reminder
- **8 audio profiles** — Flat, Bose, Sony, Apple, Sennheiser, Beats, JBL, AKG
- **macOS native** — fullscreen, keyboard shortcuts, remote command center
- **Dark / Light themes**

## How It Works

1. **Import** — user selects a folder; files are validated and queued
2. **Analyze** — Python subprocess analyzes each track (BPM, key, energy, vocals, intro/outro)
3. **Analysis sync** — per-track analysis data flows back to Swift, populates `TrackAsset.analysis`
4. **Mix** — Python crossfades tracks using equal-power blending, phase alignment, and vocal-aware ducking
5. **Stream** — 5-second float32 stereo chunks sent via named pipe to Swift
6. **Play** — `StreamAudioEngine` buffers 3 chunks then starts `AVAudioPlayerNode`

## Communication

| Channel | Direction | Format |
|---------|-----------|--------|
| Control | Cella → OpenMix | JSON on stdin (`analyze`, `mix`, `cancel`) |
| Status | OpenMix → Cella | JSON on stdout (progress, analysis, chunks, done) |
| Audio | OpenMix → Cella | Raw float32 LE, stereo, 44100 Hz, interleaved |

## Project Structure

```
Cella/
├── CellaApp.swift
├── ContentView.swift              ← engine indicator HUD
├── AudioEngine/
│   ├── OpenMixBridge.swift        ← subprocess + pipe I/O
│   ├── StreamAudioEngine.swift    ← AVAudioEngine chunk player
│   ├── MixAudioEngine.swift       ← real-time fallback
│   └── MixAudioEngine+Crossfade.swift
├── ViewModels/
│   └── PlayerViewModel.swift      ← importViaOpenMix, analysis sync
├── Views/
│   ├── Config/ConfigView.swift    ← folder import
│   ├── Cella/LineAnimationView.swift
│   └── ...
├── Models/
│   ├── TrackAsset.swift           ← track with analysis
│   ├── TrackAnalysis.swift        ← BPM, key, energy, vocals
│   └── PlayerState.swift          ← state machine + mood
└── ...

OpenMix/
├── stream_server.py               ← subprocess entry point
├── cli.py                         ← --stream, --audio-pipe flags
├── analyzer.py                    ← librosa-based analysis
├── crossfader.py                  ← equal-power crossfade
├── mixer.py                       ← ordering, beat alignment
├── audio_utils.py                 ← normalize, fade, soft limit
├── models.py                      ← AudioConfig, TrackAnalysis
└── constants.py                   ← tuning knobs
```

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `Space` | Toggle play/pause |
| `Left` | Skip backward |
| `Right` | Skip forward |

## Supported Formats

`mp3`, `wav`, `m4a`, `flac`, `aac`, `caf`, `ogg`, `aif`

File naming: `Artist - Title.ext` → parsed into artist/title metadata.

## Requirements

- macOS 15.0+
- Python >= 3.10 with `librosa`, `soundfile`, `numpy`, `scipy`, `audioread`

## Build

Open `Cella.xcodeproj` in Xcode 15+. SPM dependencies resolve automatically.

```bash
xed Cella.xcodeproj
```

## License

MIT
