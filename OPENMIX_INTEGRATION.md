# OpenMix Streaming Integration — Implementation

## Overview

Cella uses OpenMix as its sole audio engine. A Python subprocess handles analysis + crossfade rendering, streaming audio chunks back to Cella via named pipe. The Swift UI displays status, BPM/key data, and engine logs in real-time.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Cella (Swift / SwiftUI)                                        │
│                                                                 │
│  ┌──────────────────────┐   ┌──────────────────────────────┐   │
│  │  PlayerViewModel      │   │  ConfigView / FeedsView       │   │
│  │  - state machine      │   │  - folder import              │   │
│  │  - UI bindings        │   │  - EPUB reader                │   │
│  │  - analysis sync      │   │  - audio profiles             │   │
│  └──────────┬───────────┘   └──────────────────────────────┘   │
│             │                                                   │
│  ┌──────────▼───────────┐                                       │
│  │  OpenMixBridge        │                                       │
│  │  - launches subprocess│                                       │
│  │  - stdin/stdout JSON  │                                       │
│  │  - reads audio pipe   │                                       │
│  │  - analysis data sync │                                       │
│  └──────────┬───────────┘                                       │
│             │                                                   │
│  ┌──────────▼───────────┐                                       │
│  │  StreamAudioEngine    │                                       │
│  │  - AVAudioEngine      │                                       │
│  │  - chunk scheduling   │                                       │
│  │  - 3-chunk buffer     │                                       │
│  │  - continuous play    │                                       │
│  └──────────┬───────────┘                                       │
│             │                                                   │
│  ┌──────────▼───────────┐                                       │
│  │  MixAudioEngine       │  ← fallback only (if Python fails)   │
│  └──────────────────────┘                                       │
└─────────────────────────────────────────────────────────────────┘
                          │
            subprocess + named pipe + stdin/stdout
                          │
┌─────────────────────────────────────────────────────────────────┐
│  OpenMix (Python)                                               │
│                                                                 │
│  stream_server.py ─── stdin JSON commands                       │
│       │              stdout JSON status + analysis data         │
│       │              audio pipe (float32 stereo 44100Hz)        │
│       │                                                         │
│  analyzer.py ──────── tempo, key, energy, vocals, intro/outro   │
│  mixer.py ─────────── track ordering, compatibility             │
│  crossfader.py ────── tempo sync, vocal ducking, phase align   │
│  audio_utils.py ───── normalize, fade, soft limit               │
└─────────────────────────────────────────────────────────────────┘
```

---

## Communication Protocol

### Transport

| Channel | Direction | Format | Notes |
|---------|-----------|--------|-------|
| Control in | Cella → OpenMix | JSON lines on stdin | Commands: analyze, mix, cancel |
| Control out | OpenMix → Cella | JSON lines on stdout | Status + per-track analysis data |
| Audio | OpenMix → Cella | Raw float32 LE on named pipe | Interleaved stereo, 44100 Hz |

### Named Pipe

```
Cella creates: /tmp/openmix_audio_<UUID>
OpenMix opens for writing (O_WRONLY)
Cella opens for reading (O_RDONLY | O_NONBLOCK)
```

### Commands (Cella → OpenMix)

```json
{"cmd": "analyze", "tracks": ["/path/to/track1.mp3", "/path/to/track2.mp3"]}
{"cmd": "mix", "order": [0, 2, 1, 3]}
{"cmd": "cancel"}
```

### Status Messages (OpenMix → Cella)

```json
{"type": "ready", "sample_rate": 44100, "channels": 2}
{"type": "progress", "stage": "analyzing", "current": 2, "total": 8, "file": "track1.mp3"}
{"type": "progress", "stage": "mixing", "current": 3, "total": 7, "file": "track4.mp3"}
{"type": "analysis_done", "track_count": 8, "tracks": [
  {"file": "track1.mp3", "path": "/path/to/track1.mp3", "tempo": 124.5, "key": "A", "duration": 234.5, "energy": [0.12, 0.15, ...], "energy_avg": 0.14, "intro_end": 8.2, "outro_start": 210.3},
  ...
]}
{"type": "chunk_ready", "chunk_index": 5, "bytes": 1764000, "progress": 0.35}
{"type": "done", "duration": 300.5, "chunks_sent": 60}
{"type": "error", "message": "Analysis failed for track3.mp3"}
```

### Audio Data (named pipe)

- Format: raw float32, little-endian, interleaved stereo
- Sample rate: 44100 Hz
- Chunk size: 5 seconds = 5 × 44100 × 2 × 4 = 1,764,000 bytes

---

## Data Flow

### 1. Import

```
User clicks Import Folder
  → ConfigView.selectFolder()
    → viewModel.importViaOpenMix(url:)
      → stops all existing playback
      → discovers audio files
      → creates MixQueue (empty analyses)
      → launches OpenMixBridge.start()
        → creates named pipe
        → launches: python3 cli.py --stream --audio-pipe /tmp/openmix_audio_<UUID>
        → opens pipe for reading
        → starts stdout reader
        → starts audio reader
      → sends: {"cmd":"analyze","tracks":[...]}
```

### 2. Analysis

```
OpenMix                              Cella
──────                               ─────
for each track:
  analyze_track()
  stdout: {"type":"progress","stage":"analyzing",...}

  stdout: {"type":"analysis_done","track_count":8,"tracks":[
    {"file":"track1.mp3","tempo":124.5,"key":"A","energy":[...],...},
    ...
  ]}

                                   ← handleOpenMixStatus(.analysisDone)
                                     → applyOpenMixAnalysis()
                                       → populates TrackAsset.analysis
                                       → sets currentTrackBPM, currentTrackKey
                                     → sends: {"cmd":"mix","order":[0,1,2,...]}
```

### 3. Mix + Playback

```
OpenMix                              Cella
──────                               ─────
mixing tracks...
  ensure_smooth_flow()
  align_beats()
  crossfader.create()
    → tempo sync via _apply_gradual_tempo_ramp()
    → vocal-aware ducking
    → phase correlation alignment

  for each 5s chunk:
    write audio_pipe: [float32 data]
    stdout: {"type":"chunk_ready",...}

                                   ← handleOpenMixChunk(data)
                                     → streamEngine.scheduleChunk(data)
                                       → deinterleave stereo
                                       → AVAudioPlayerNode.scheduleBuffer()

                                   ← after 3 chunks buffered:
                                     streamEngine.startPlayback()
                                     playerState = .playing

  stdout: {"type":"done","duration":300.5}

                                   ← handleOpenMixStatus(.done)
```

### 4. Fallback (on failure)

```
If Python subprocess fails:
  1. openMixBridge.stop()
  2. streamEngine?.stop()
  3. importFolder(url:)  ← existing real-time MixAudioEngine path
```

---

## Analysis Sync — Line Animation

OpenMix analysis data flows to the Swift animation system:

```python
# stream_server.py sends per-track:
{
    "tempo": 124.5,           # BPM
    "key": "A",               # musical key (C, C#, D, ...)
    "duration": 234.5,        # seconds
    "energy": [0.12, ...],    # RMS energy profile (~100 points)
    "energy_avg": 0.14,       # average RMS
    "intro_end": 8.2,         # intro section end (seconds)
    "outro_start": 210.3      # outro section start (seconds)
}
```

```swift
// PlayerViewModel.swift
var currentTrackBPM: Double?      // drives animation speed
var currentTrackKey: String?      // drives color/mood

// applied to TrackAsset.analysis:
// - energyProfile → currentEnergyValue → trail speed
// - bpm → MusicMood.from(analysis:) → animation pattern
// - keySignature → mood classification (major/minor)
```

```
LineAnimationView
  ← reads viewModel.currentEnergyValue
    ← reads mixQueue.currentTrack.analysis.energyProfile
      ← populated from OpenMix analysis_done data
```

---

## File Summary

| File | Status | Purpose |
|------|--------|---------|
| `OpenMix/stream_server.py` | NEW | Subprocess entry, stdin/stdout JSON, analysis data, audio pipe |
| `OpenMix/cli.py` | MODIFIED | Added `--stream` and `--audio-pipe` flags |
| `OpenMix/analyzer.py` | MODIFIED | Added optional `progress_callback` |
| `OpenMix/crossfader.py` | MODIFIED | Added `create_chunked()` generator |
| `Cella/AudioEngine/OpenMixBridge.swift` | NEW | Subprocess lifecycle, pipe I/O, analysis parsing |
| `Cella/AudioEngine/StreamAudioEngine.swift` | NEW | AVAudioEngine chunk scheduling, buffer-ahead |
| `Cella/AudioEngine/MixAudioEngine.swift` | MODIFIED | Added `scheduleChunk()` for fallback |
| `Cella/ViewModels/PlayerViewModel.swift` | MODIFIED | OpenMix import, analysis sync, BPM/Key, engine log |
| `Cella/Views/Config/ConfigView.swift` | MODIFIED | Always uses OpenMix (no toggle) |
| `Cella/ContentView.swift` | MODIFIED | Engine indicator + log overlay (top-right) |

---

## Chunk Scheduling

```
OpenMix sends 5-second chunks
Cella buffers 3 chunks before starting playback

Timeline:
  t=0s    Chunk 0 [0-5s]     → scheduled
  t=5s    Chunk 1 [5-10s]    → scheduled
  t=10s   Chunk 2 [10-15s]   → scheduled → triggers playback start
  t=15s   Chunk 3 [15-20s]   → scheduled while 0-2 play
  ...
```

| Metric | Value |
|--------|-------|
| Chunk size | 5 seconds |
| Bytes per chunk | 1,764,000 |
| Initial latency | ~10-15s (3 chunks buffered) |
| Throughput | ~350 KB/s |

---

## UI Elements

### Engine Indicator (top-right corner)
- Shows "OpenMix" (green) or "Real-Time" (orange) during playback
- Smooth fade/slide animation on state change
- Visible only when playing or in auto-mix transition

### Engine Log (top-right, below indicator)
- Last 8 log lines in 8pt monospaced font
- Rolling 30-line buffer
- Entries: track ended, crossfading, analysis synced, errors, fallback

### Analysis Progress
- Progress bar in ConfigView during analysis phase
- Track count display

---

## Dependencies

### Python (OpenMix)
```
librosa
soundfile
numpy
scipy
audioread
```

### Swift (Cella)
```
AVFoundation
Foundation
```

---

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Python not found | Error message shown, fallback to real-time |
| Python dependencies missing | Error shown, fallback to real-time |
| Analysis fails for track | Track skipped, logged, continues with rest |
| Named pipe fails | Fallback to real-time engine |
| Process crashes mid-mix | `terminationHandler` → fallback to real-time |
| New import while playing | Stops all old playback first |
