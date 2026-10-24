# Cella Audio Engine — Implementation

## Overview

Cella's audio engine is a **single-process, native-Swift pipeline**. Analysis, ordering, and crossfade rendering all run in-app with no subprocesses, no named pipes, and no JSON IPC. The older OpenMix Python engine (analyze/mix via `stream_server.py`, audio streamed back as float32 chunks) is fully retired; protocol remnants survive only in API names like `PlayerViewModel.importViaOpenMix(url:)`, which now fronts the native import flow.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Cella (Swift / SwiftUI)                                         │
│                                                                  │
│  PlayerViewModel ─── orchestrates the whole pipeline             │
│  ├── importViaOpenMix(url:)      pack (.cella) + artist filters  │
│  ├── runs analysis tasks         background, throttled           │
│  ├── owns queue state            MixQueue / TrackAsset           │
│  │                                                               │
│  ├──► TrackAnalyzer (actor)      spfk-tempo / musical-analysis / │
│  │    reports tempo, key, energy, vocals, structure              │
│  │    caches results as .cellax  per-album Cache/ folder         │
│  │                                                               │
│  ├──► MixEngine                  directed pairing scores +       │
│  │    buildMixQueue            weighted ordering (TSP-style)    │
│  │                                                               │
│  ├──► Crossfader                 transition params + curve math  │
│  │    computeCrossfadeParams   equal-power, vocal-aware          │
│  │                                                               │
│  └──► MixAudioEngine             AVAudioEngine playback +        │
│       scheduled seam transitions at generous lead time           │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

All communication between these pieces is in-process async Swift. There is no external engine to keep alive.

## Data Flow

### 1. Import

```
User action (Cluster tab, drag & drop, Finder open, palette)
  → PlayerViewModel.importViaOpenMix(url:)
      → requires a .cella playlist pack (folders must be renamed with a
        .cella extension)
      → stop / clear old state unless blending
      → discovery of audio files (whitelist extensions)
      → MixQueue created; optional artistFilter solo-scopes the pack
      → optional blend: capture the currently playing track so the next
        mix transitions out of it (blendPending)
```

Import modes:

| Mode | Behavior |
|------|----------|
| Fresh import | Stop playback, load pack, order queue, play from requested start file |
| Blend (`blend: true`) | Keep current track playing; the new pack's first mix starts *from* it |
| Artist filter (`artistFilter:`) | Queue only that artist's files inside the pack |

### 2. Analysis

`TrackAnalyzer` is a Swift actor, so analysis tasks are thread-safe and concurrent.

- Built on the on-device SPFK packages: **spfk-tempo**, **spfk-musical-analysis**, **spfk-loudness** (plus spfk-audio-base headers they carry).
- Produces per-track: tempo (BPM), musical key, RMS energy profile, average energy, vocal boundary detection, intro/outro structure points, spectral features.
- Results land on `TrackAsset.analysis`; BPM/key feed the mood-aware crossfade parameters, structure shapes transition points.
- **Caching:** each analysis of an audio file is written to a `.cellax` file inside that album's `Cache/` subfolder. Cache is invalidated when the audio file is newer than its cache.
- Background generation (for the played album) runs with a 200 ms throttle between tracks and yields the main thread between them.
- A track that throws is skipped and logged; playback continues without scores.

### 3. Ordering

`MixEngine.buildMixQueue` arranges the queue as a directed path through the tracks, anchored on the current/first track, optimizing total transition compatibility.

Compatibility score between two tracks (0.0–1.0) is a weighted blend:

| Component | Weight | What it measures |
|-----------|--------|------------------|
| Outro→intro energy | **0.55** | Seam energy match (dominant: the seam itself matters most) |
| Key | 0.18 | Harmonic compatibility |
| Tempo | 0.14 | BPM distance |
| Spectral | 0.07 | Timbre/spectral fit |
| Vocal | 0.06 | Vocal phrase overlap |

Hard caps then clamp implausible pairings so a high raw score cannot mask a bad key/energy seam. `MixTuning` aims the incoming track slightly hotter than the outgoing ending so joints never sag.

### 4. Playback

`MixAudioEngine` plays tracks in real time through AVAudioEngine — there is no chunk staging or buffer-ahead window anymore; audio starts on import.

### 5. Crossfade transitions

At track seams the engine schedules a transition with generous lead time (sized to cover the worst-case `Crossfader.computeCrossfadeParams` output: 1.3× configured duration plus bar quantization). Per transition:

- Equal-power crossfade curves (quintic smoothstep plus cos/sin variants).
- Tempo alignment and key correction across the seam.
- Vocal-aware ducking via `VocalTransitionStrategy`:

| Strategy | When |
|----------|------|
| `standard` | Neither track has vocals |
| `duckIncoming` | Only outgoing has vocals — incoming ducks under its phrases |
| `duckOutgoing` | Only incoming has vocals — outgoing ducks under its phrases |
| `priorityOutgoing` | Both vocal, outgoing stronger — incoming ducks |
| `priorityIncoming` | Both vocal, incoming stronger — outgoing ducks |

Each finished/happening transition is recorded in a `TransitionLog` entry (from-track, to-track, parameters) for debugging the mix.

### 6. DSP — Orquesta

`OrquestaDSP` holds the shared EQ/surround/stereo-width geometry used by the main engine:

- 10-band parametric profile EQ: 31 Hz → 16 kHz.
- Four-band surround staging (low-shelf + parametric bands).
- Stereo width factors (`StereoWidthEffect`).

Config-tab presets (`OrquestaPreset`): `natural`, `calido`, `oceano`, `aurora`, `frutigerAurora`, plus a user `custom` preset persisted in defaults.

## File Summary

| File | Role |
|------|------|
| `Cella/ViewModels/PlayerViewModel.swift` | Pipeline orchestrator: import, analysis tasks, ordering, playback control, blend/solo |
| `Cella/Analyzer/TrackAnalyzer.swift` | Actor-performing on-device analysis (SPFK), disk caching |
| `Cella/Utilities/AnalysisCache.swift` | `.cellax` read/write + invalidation |
| `Cella/Mixer/MixEngine.swift` | Compatibility scoring, queue ordering |
| `Cella/Crossfader/Crossfader.swift` | Transition params + crossfade curve math |
| `Cella/AudioEngine/MixAudioEngine.swift` | Real-time playback engine + seam scheduling |
| `Cella/AudioEngine/OrquestaDSP.swift` | Shared EQ/surround/width geometry |
| `Cella/AudioEngine/StereoWidthEffect.swift` | Stereo width processing |
| `Cella/Models/MixQueue.swift` | Queue model (jump/seek/move primitives) |
| `Cella/Models/TrackAsset.swift` / `TrackAnalysis.swift` | Track + analysis data model |
| `Cella/Models/TransitionLog.swift` | Per-transition records |
| `Cella/Models/AudioConfig.swift` | Global engine tuning (`AudioConfig`, `MixTuning`) |

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Analysis throws for a track | Track skipped in that pass, error logged, playback continues |
| Audio file unreadable | Excluded during discovery |
| Non-`.cella` folder imported | Rejected with "Rename folder with .cella extension" |
| Cache stale (audio newer) | Re-analyzed, cache rewritten |
| Visuals missing for pack | Visuals reset so previous pack's art can't linger |
