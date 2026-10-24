# Product

<!-- impeccable:product-schema 1 -->

## Platform

macOS

## Users

Personal music listener with a local audio library (mp3, wav, m4a, flac, aac, caf, ogg, aif). They want seamless, DJ-quality automated transitions between tracks without manual mixing — a listening experience that feels curated, not shuffled.

## Product Purpose

Cella is a macOS music player that analyzes local audio tracks (BPM, key, energy, vocals) and crossfades them in optimal order using a Python-powered automix engine. The player makes a personal music library feel like a continuous, flowing DJ set — with a distinctive visual identity (9×5 dot matrix, procedural line visualizer, mood system) that makes the experience feel alive, not just functional.

## Positioning

The automix engine and the visual experience are inseparable differentiators. OpenMix handles beat-aligned crossfades, vocal-aware ducking, and compatibility scoring (key, energy, tempo, spectral similarity) — streamed back to a Swift frontend that renders mood-driven dot matrix animations and a Catmull-Rom line visualizer. Neither piece works without the other; the engine feeds the visuals, the visuals make the engine tangible.

## Operating Context

1. User selects a folder of audio files
2. Python subprocess analyzes each track (BPM, key, energy profile, vocal detection, intro/outro)
3. Analysis data flows back to Swift — populates track assets, drives mood system and visualizer
4. Tracks ordered by compatibility scoring (TSP heuristic with 2-opt improvement)
5. Crossfades rendered by Python: equal-power curves, phase alignment, zero-crossing boundaries, vocal-aware ducking
6. 5-second float32 chunks streamed via named pipe to AVAudioEngine
7. User sees dot matrix mood animation, line visualizer reacts to energy, can skip/pause/seek

## Capabilities and Constraints

- **Automix engine:** BPM/key/energy analysis, beat-aligned crossfades, compatibility scoring, vocal-aware ducking, phase alignment
- **Stream architecture:** Python subprocess + named pipe + stdin/stdout JSON IPC; 3-chunk buffer-ahead continuous playback
- **Fallback engine:** Real-time MixAudioEngine if Python subprocess fails
- **Visual system:** 9×5 dot matrix (mood animations, text scroller, pixel font), Catmull-Rom line visualizer with energy-reactive trail
- **8 audio profiles:** Flat, Bose, Sony, Apple, Sennheiser, Beats, JBL, AKG
- **EPUB reader:** Sentence-by-sentence with progress tracking, cover art, water reminder
- **LRC editor:** Enhanced LRC recording and editing
- **Cluster library:** Music library organization
- **Video boomerang maker:** Export tool
- **Dark/Light themes**
- **macOS 15.0+ required**
- **Python >= 3.10** with librosa, soundfile, numpy, scipy, audioread
- **SPM dependencies:** spfk-tempo, spfk-musical-analysis, spfk-loudness, spfk-audiobase, Accelerate
- **File naming:** `Artist - Title.ext` parsed into artist/title metadata
- **Keyboard shortcuts:** Space (play/pause), Left (skip back), Right (skip forward)

## Brand Commitments

- Name: **Cella**
- Open source (MIT license)
- No commercial intent — personal/hobby project

## Evidence on Hand

- Full working Swift/SwiftUI codebase (`Cella/`)
- Full working Python automix engine (`OpenMix/`) with tests
- Architecture documentation (`README.md`, `Cella.md`)
- OpenMix integration doc (`OPENMIX_INTEGRATION.md`)
- Tab bar icon asset (`cellaTabBarIcon.gif`)
- Sample audio file (`airpodsMaxOnline.m4a`)

## Product Principles

1. **Automix first** — the core value is seamless, intelligent transitions. Every feature either feeds the engine or makes the listening experience richer.
2. **Visual identity is not decoration** — the dot matrix, line visualizer, and mood system are how the user *feels* the music, not just sees the player.
3. **On-device analysis** — no cloud, no accounts. The user's music stays local, analyzed locally.
4. **Engine resilience** — Python subprocess failure falls back to real-time crossfade. The music never stops.
5. **Local-first tooling** — EPUB reader, LRC editor, cluster library, boomerang maker all serve a local, offline workflow.

## Accessibility & Inclusion

No specific accessibility requirements established. macOS platform conventions (VoiceOver, keyboard navigation) apply by default.
