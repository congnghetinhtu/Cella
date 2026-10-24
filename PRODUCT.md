# Product

<!-- impeccable:product-schema 1 -->

## Platform

macOS

## Users

Personal music listener with a local audio library (mp3, wav, m4a, flac, aac, caf, ogg, aif) organized into folders. They want seamless, DJ-quality automated transitions between tracks without manual mixing — and when they care about lyrics, they want to author and time them against the audio instead of scraping sickly LRC files. A listening experience that feels curated, not shuffled.

## Product Purpose

Cella is a macOS music player that analyzes local audio tracks (BPM, key, energy, vocals, structure) on-device and crossfades them in optimal order using a native Swift automix engine. It makes a personal folder library feel like a continuous, flowing DJ set — unified under one Frutiger Aurora visual language (glass surfaces, aurora gradients) with a built-in CLARC lyric studio for timing lyrics to the mix.

## Positioning

Three differentiators are inseparable:

1. **The automix engine** — energy-led compatibility scoring, vocal-aware equal-power crossfades, blend-into-what's-playing — all native, no cloud, no external processes.
2. **The visual experience** — one Frutiger Aurora language applied everywhere: glass surfaces, aurora gradients, halo highlights. The engine drives the sound; the interface stays calm and readable.
3. **CLARC** — a readable, spec-driven lyric format (LRC-compatible timestamps, vocalist attribution, harmony lines, dual-line layout) with an in-app recording studio. The lyric layer is a first-class feature, not an afterthought.

## Operating Context

1. User picks one `.cluster` library (remembered across launches); it holds `.cella` packs
2. Browsing happens in Cluster: packs → artists → albums; `.cue`-classified packs show [LRC] badges; NEW badges mark albums added since first open
3. Opening a pack analyzes its audio on-device (BPM, key, energy, vocal boundaries, intro/outro) and caches results in per-album `Cache/*.cellax`
4. Tracks are ordered by directed compatibility scoring (energy-led weights + hard caps), anchored on the current track
5. Playback runs in real time through AVAudioEngine; at seams, equal-power vocal-aware crossfades are scheduled with generous lead time
6. Lyrics scroll line-by-line with vocalist attribution and `[DUO]` splits
7. In the Clarc tab they can record and time lyrics (R/M), edit, bulk paste, and save `.clarc` files into the pack's `lrc/` folder
8. `/` opens a mouse-anchored command palette from anywhere for tabs, tracks, and lyric-insert commands

## Capabilities and Constraints

- **Automix engine:** on-device analysis (tempo, key, energy profile, vocal boundaries, intro/outro, spectral features), weighted directed ordering (outro→intro energy 0.55, key 0.18, tempo 0.14, spectral 0.07, vocal 0.06 + hard caps), `.cellax` analysis cache per album
- **Crossfades:** equal-power curves (quintic smoothstep + cos/sin), tempo-aligned, key-corrected, five vocal transition strategies (standard, duck incoming/outgoing, priority incoming/outgoing), per-transition logs
- **Blend & solo:** blend a new playlist into the currently playing track; solo an artist within a pack (`S` key or UI)
- **Cluster library:** one remembered `.cluster` library; `.cella` packs; `.cue`-based album classification; per-album `.cellax` cache counts; NEW album badges; artist folder-open scene; first-visit guided tour (6-page card) from a floating glass pill
- **CLARC/1 format:** spec-driven ([`clarc/FORMAT.md`](clarc/FORMAT.md)) with a tolerant parser round-trip; `.clarc` files live in pack `lrc/` folders
- **Lyric studio (Clarc tab):** timed recording (R toggles record, M stamps the current line), line editing, bulk paste, format tutorial ("How to Clarc?", 5 pages), save with stale-`.lrc` cleanup
- **Command palette:** `/` opens at the mouse position; shows the current lyric line, tabs, queue tracks, and commands (`insertInit`, `insertBreak`, `addLy`); keyboard-navigable
- **Visual system:** one Frutiger Aurora theme everywhere — glass surfaces, aurora gradients, halo highlights, MixOrb loading spinner. Orquesta presets change EQ and staging only, never the look.
- **Orquesta audio:** 10-band parametric EQ as a half-circle orchestra stage, bundled surround-staging presets (natural, calido, oceano, aurora, frutiger aurora + custom)
- **CueLab:** ExactAudioCopy-style `.cue` sheet builder with bulk rename ("NN - Title"), album moves, `lrc/` folder creation
- **One visual language:** Frutiger Aurora glass everywhere; the Orquesta presets are audio profiles (EQ curve + surround staging), not looks
- **macOS 15.0+ required**
- **SPM dependencies:** spfk-tempo, spfk-musical-analysis, spfk-loudness, SignalKit
- **File naming:** `Artist - Title.ext` parsed into artist/title metadata; `.cue` performer data takes precedence
- **Keyboard shortcuts:** Space (play/pause), ←/→ (skip), L (lyric mode), S (solo), `/` (palette), Esc (dismiss), R/M (record/stamp in Clarc tab)

## Brand Commitments

- Name: **Cella**
- Open source (MIT license)
- No commercial intent — personal/hobby project

## Evidence on Hand

- Full working Swift/SwiftUI codebase (`Cella/`) — single-process native engine
- Engine implementation doc (`ENGINE.md`)
- Product README (`README.md`)
- CLARC format spec + migration guide (`clarc/FORMAT.md`, `clarc/MIGRATING_FROM_LRC.md`)
- CLARC template + worked example (`clarc/defaultFormat.clarc`, sample LRC)
- Sample audio (`clarc/Trễ Giờ Cơm….m4a`)
- Tab bar icon asset (`cellaTabBarIcon.gif`)

## Product Principles

1. **Automix first** — the core value is seamless, intelligent transitions. Every feature either feeds the engine or makes the listening experience richer.
2. **Visual identity is not decoration** — the Frutiger Aurora glass language is one coherent surface for everything, not a theme switcher.
3. **On-device everything** — no cloud, no accounts, no external processes. The user's music stays local and analyzed locally.
4. **One process, no fragility** — the engine is native Swift; there is no subprocess protocol that can fail.
5. **Lyrics are a studio, not a viewer** — CLARC, the Clarc tab, and the guides treat lyric authoring as a first-class workflow.
6. **Local-first tooling** — CueLab and pack tooling serve a local, offline workflow.

## Accessibility & Inclusion

- **Reduce Motion** is respected in the tab bar, queue, and animations — motion stutters down to discrete state changes.
- System keyboard navigation and other macOS platform conventions (VoiceOver) apply by default; the command palette is fully keyboard-driven (`↑ ↓ Enter Esc`).
- No specific accessibility requirements beyond these are established.
