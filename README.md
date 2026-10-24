# Cella

macOS music player that turns a local folder library into a continuous, DJ-quality set — on-device analysis, compatibility-scored ordering, and vocal-aware crossfades, all native Swift, wrapped in a Metro Glass interface. Includes **CLARC**, a readable lyric format, with a built-in recording/editing studio.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Cella (Swift / SwiftUI — one process, no Python)                │
│                                                                  │
│  PlayerViewModel ─── orchestrator                                │
│  ├── TrackAnalyzer (actor)   on-device analysis via SPFK         │
│  │                            packages; .cellax disk cache       │
│  ├── MixEngine               compatibility scoring + queue       │
│  │                            ordering (energy-led weights)      │
│  ├── Crossfader              equal-power curves, key-corrected,  │
│  │                            vocal-aware transition math        │
│  ├── MixAudioEngine          AVAudioEngine playback with         │
│  │                            scheduled seam crossfades          │
│  └── PreviewAudioEngine      independent engine behind the       │
│                               floating preview mini player       │
│
│  Views (4 tabs): Cluster · Cella · Clarc · Config
└──────────────────────────────────────────────────────────────────┘
```

See **[ENGINE.md](ENGINE.md)** for the full engine implementation notes.

## Tabs

| Tab | What lives there |
|-----|------------------|
| **Cluster** | Library browser: a `.cluster` library holds `.cella` packs; browse packs, artists, albums, and open artist folders. Includes CueLab and the first-visit Cluster guide (floating glass pill, bottom-right) |
| **Cella** | The player: full-screen playback, Apple Music-style lyrics, queue reorder, dot-matrix patterns, artist images/videos, engine transitions |
| **Clarc** | Lyric studio: record timings with R/M, edit lines, bulk paste, save `.clarc` files; "How to Clarc?" format tutorial next to Undo |
| **Config** | Audio & app settings: Orquesta EQ stage (audio profiles), quick guide, about |

## Features

- **Automix engine** — native on-device analysis (BPM, musical key, energy profile, vocal boundaries, intro/outro) with a weighted, directed ordering pass led by outro→intro energy seam matching
- **Vocal-aware crossfades** — equal-power curves with five vocal transition strategies (duck/priority), tempo-aligned and key-corrected seams
- **Blend import** — crossfade a new playlist *into* whatever is currently playing
- **Artist solo** — scope playback and visuals to one artist inside a pack
- **Cluster library** — Apple Photos-style one-time library pick, `.cluster` → `.cella` packs → artists/albums, `.cue`-based pack classification, NEW badges for albums added later
- **CLARC/1 lyric format** — sections-based, LRC-compatible timestamps, vocalist attribution (`[v1]`, `[v1&v2]`), harmony lines (`[har]`), `[DUO]` dual-line layout; spec in [`clarc/FORMAT.md`](clarc/FORMAT.md)
- **Lyric studio (Clarc tab)** — timed recording (R toggles, M stamps the current line), editing tools, bulk paste, round-trip parse/write that preserves unknown metadata
- **Command palette** — `/` opens anywhere (except the Clarc editor), anchored to your mouse position with a bloom animation; shows the current lyric line, tabs, queue tracks, and lyric-insert commands
- **Dot-matrix display** — 9×5 pattern matrix with mood-driven animations (analyzing, automix, skip, smiley...) and a 3×5 pixel font text scroller
- **Line visualizer** — procedurally generated path with energy-reactive trail sweeping the Frutiger Aurora palette (green→aqua→sky→sun)
- **Artist visuals** — pack `cma/` folders serve images or videos (including `.cma` motion files) synced to the playing track's artist
- **Orquesta EQ stage** — 10-band parametric EQ presented as a half-circle orchestra stage (each seat is a band), bundled surround staging presets: natural, calido, oceano, aurora, frutiger aurora + custom
- **Preview mini player** — drop/open an audio file anywhere and get a floating Quick Look-style card with its own Orquesta panel, above the main app even in fullscreen
- **CueLab** — build ExactAudioCopy-style `.cue` sheets: rename ("NN - Title" detect), move files into albums, write `.cue`, create `lrc/` folders
- **One visual language** — Frutiger Aurora glass everywhere (trail/glow palette sweeps green→aqua→sky→sun); look and sound are separated: preset choices are audio profiles, not themes
- **macOS native** — custom circle cursor with press animation, drag-to-switch tab bar, keyboard shortcuts, remote-ready playback

## How It Works

1. **Import** — pick/select a `.cella` pack (Cluster tab, palette, drag & drop, or Finder "Open With")
2. **Analyze** — `TrackAnalyzer` computes tempo, key, energy, vocals, structure per track (cached in the album's `Cache/*.cellax`, invalidated when audio is newer)
3. **Order** — `MixEngine.buildMixQueue` walks compatibility scores (energy 0.55, key 0.18, tempo 0.14, spectral 0.07, vocal 0.06 + hard caps) and anchors the current track at index 0
4. **Play** — `MixAudioEngine` streams the queue in real time through AVAudioEngine
5. **Crossfade** — at seams the engine schedules equal-power, vocal-aware transitions with generous lead time, logging each one
6. **Listen** — lyric lines scroll with the playhead; dot-matrix and line visuals react to energy and mood

## Library layout

```
My Library.cluster/              ← the one library Cella remembers
├── Some Playlist.cella/         ← a pack = playlist folder
│   ├── audio files              ← mp3, wav, m4a, flac, aac, caf, ogg, aif
│   ├── Album (optional)/        ← per-album folders (classified via .cue)
│   │   ├── audio files
│   │   ├── .cue                 ← per-album cue sheet (artist + track names)
│   │   ├── Cache/               ← *.cellax analysis cache (generated)
│   │   └── lrc/                 ← *.clarc lyrics (generated by Clarc tab)
│   ├── cma/                     ← artist visuals: *.cma / *.mp4 / *.gif video
│   │   └── <Artist>/              or jpg/png/webp stills, per artist
│   └── lrc/                     ← pack-level lyrics fallback
```

- Naming: `Artist - Title.ext` is parsed into artist/title metadata; `.cue` performer/track data takes precedence when present.
- `cma`, `lrc`, `Cache` folders are never listed as albums.

## Command palette

Press `/` (any tab except the Clarc editor) to open the palette at your mouse position.

- **Current line** — the lyric at the playhead appears immediately; selecting it scrolls the player to that line
- **Tabs** — jump to Cluster/Cella/Clarc/Config
- **Tracks** — queue matches; selecting jumps the player there
- **Commands** — `insertInit` (`[00:00.00]` opener), `insertBreak` (break line at playhead), `addLy "text"` (insert a lyric line at playhead)
- `↑ ↓` move, `Enter`/click runs, `Esc` closes

## Keyboard shortcuts

| Key | Action | Where |
|-----|--------|-------|
| `Space` | Play / pause | Cella tab |
| `←` / `→` | Skip backward / forward | Cella tab |
| `L` | Cycle lyric mode | Cella tab |
| `S` | Toggle artist solo | Cella tab |
| `/` | Open / close command palette | Anywhere but Clarc tab |
| `↑` / `↓` | Move palette selection | Palette open |
| `Enter` | Run highlighted suggestion | Palette open |
| `Esc` | Close palette / dismiss guides / clear folder scene | Everywhere |
| `R` | Start / stop timed recording | Clarc tab |
| `M` | Stamp a lyric line at the current time | Recording in Clarc tab |

Shortcuts never fire while typing in a text field, and the Clarc editor ignores `/` so lyric text can contain it.

## Clarc lyric format

Cella's lyrics live in **CLARC/1** files — a readable, line-oriented format that keeps LRC's `[mm:ss.xx]` timestamps but separates song info from lyric events with `[metadata]` / `[lyrics]` section headers.

```text
CLARC/1

[metadata]
title: Trễ Giờ Cơm
artist.1: Quang Hùng MasterD
writer: Trịnh Thăng Bình

[lyrics]
[00:00.00] …
[00:19.46] [v1] Khi xưa tan trường
[01:27.29] [v1&v2] Là có mẹ, có cha, có chúng ta
[har 01:28.00] (Ah-ah)
```

Full spec: [`clarc/FORMAT.md`](clarc/FORMAT.md) · Coming from LRC: [`clarc/MIGRATING_FROM_LRC.md`](clarc/MIGRATING_FROM_LRC.md). The Clarc tab is a full studio for this format: record timings against the audio, edit, bulk paste, and save to the pack's `lrc/` folder as `.clarc` (stale `.lrc` twins are cleaned up automatically).

The built-in "How to Clarc?" tutorial (button next to Undo in the Clarc tools bar) walks the whole format in 5 pages.

## Supported Formats

Audio: `mp3`, `wav`, `m4a`, `flac`, `aac`, `caf`, `ogg`, `aif`

Other: `.cella` packs, `.cluster` libraries, `.clarc` lyrics, `.cue` sheets, `.cellax` analysis cache, `.cma` motion files, images for artist visuals.

## Requirements

- macOS 15.0+
- Xcode 16+ (Swift 6 toolchain)
- SPM dependencies resolve on first build: `spfk-tempo`, `spfk-musical-analysis`, `spfk-loudness` (ryanfrancesconi), `SignalKit`

## Build

Open the project in Xcode:

```bash
xed Cella.xcodeproj
```

or build from CLI:

```bash
xcodebuild -project Cella.xcodeproj -scheme Cella \
  -destination 'platform=macOS,arch=arm64' build
```

## Docs

| Doc | Contents |
|-----|----------|
| [ENGINE.md](ENGINE.md) | Audio engine implementation details |
| [PRODUCT.md](PRODUCT.md) | Product definition |
| [clarc/FORMAT.md](clarc/FORMAT.md) | CLARC/1 lyric format specification |
| [clarc/MIGRATING_FROM_LRC.md](clarc/MIGRATING_FROM_LRC.md) | LRC → CLARC conversion guide |

## License

MIT
