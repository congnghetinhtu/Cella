# CellaMotionsView Redesign — Implementation Plan

## Goal

Make CMA editor more responsive, fluid, and usable. Fix bugs, add missing features from CMA_OPTIONS.md spec, improve UX polish.

---

## Phase 1: Bug Fixes & Quick Wins

### 1a. Wire up `nudgeTrimEnd`

`nudgeTrimEnd(_:)` is defined at line 430 but never called from UI. The nudge row only nudges `trimStart`.

**In `nudgeRow`:**
- Change the right-side nudge buttons to call `nudgeTrimEnd` instead of `nudgeTrimStart`
- Add a second pair: `trimStart` nudge (left group) + `trimEnd` nudge (right group)

```
Fine: [◀◀ 0.1] [0.1 ▶]   [▶▶ 0.1] [0.1 ◀]
       └─ trimStart ─┘     └─ trimEnd ─┘
```

### 1b. Fix `formatPreset` for 0.3 and 0.5

Current: `secs == 0.3 ? "0.3" : secs == 0.5 ? "0.5" : "\(Int(secs))"`
This works but is fragile. Replace with `String(format: "%.1f", secs)` for all values.

### 1c. Remove redundant Slider

The `scrubBar` has a native `Slider` AND the `FilmstripBar` has a drag playhead. Two scrubbing mechanisms is confusing. **Remove the Slider.** Keep only the filmstrip playhead for scrubbing. The time labels move to a unified readout row.

---

## Phase 2: Unified Time Readout

Replace the scattered time displays (video player badge, scrubBar labels, readout cells) with one clean row below the video player.

### New layout:

```
┌──────────────────────────────────────────────────────┐
│  0:18.4 ──────────●────────────────────── 42:10     │  ← scrub slider (thin, custom)
│  In 18.4s    Dur 1.0s    Out 18.5s                  │  ← readout cells
└──────────────────────────────────────────────────────┘
```

**Implementation:**
- Remove the `now` badge overlay from `videoPlayer`
- Remove the old `scrubBar` entirely
- Create `timeRow` that combines:
  - Current time (left)
  - Thin custom scrub slider (center, stretches)
  - Total duration (right)
- Keep `readoutCells` below the slider for In/Dur/Out

### Custom thin scrub slider

Replace the native `Slider` with a thin custom bar (4px height) that matches the theme. The playhead position is a circle (10px) that the user can drag. This is more precise and visually lighter than a full OS slider.

```swift
struct ScrubBar: View {
    let duration: Double
    @Binding var currentTime: Double
    let onSeek: (Double) -> Void
    // Thin bar + draggable circle playhead
}
```

---

## Phase 3: Zoom / Detail Filmstrip

This is the biggest change. The spec requires two-level navigation.

### State

```swift
@State private var zoomed: Bool = false
@State private var zoomCenter: Double = 0  // center time of zoom window
@State private var zoomThumbs: [NSImage] = []
```

### Behavior

- **Overview** (`zoomed == false`): FilmstripBar shows full video duration, all thumbnails. Same as current.
- **Detail** (`zoomed == true`): FilmstripBar shows a ~5-second window centered on `zoomCenter`. Thumbnails are regenerated at higher density for this window. Selection band fills most of the strip. Edge handles are more prominent.

### Toggle

- Magnifier icon button between filmstrip and controls
- Auto-zoom when Mark In/Out is tapped (zooms to selection)
- Auto-zoom out when selection moves beyond visible window
- Animated transition between modes

### FilmstripBar changes

Add a `zoomRange: ClosedRange<Double>?` parameter:
- `nil` = overview mode (full duration)
- Set = detail mode (shows only that time range)

The `x()` function maps time to pixel position within the visible range instead of full duration.

### Thumbnail regeneration

When zooming in, call `FilmstripGenerator.generateThumbnails(from:count:height:start:end:)` with the zoom window. Cache in `zoomThumbs`. Show a brief loading state if regenerating.

---

## Phase 4: Loop Count UI

### New `loopRow`

Place after `presetRow`:

```
Repeats: [−]  3  [+]
```

**Implementation:**
- HStack with "Repeats:" label, minus button, count text, plus button
- `loopCount` clamped 1...8
- Buttons use `.bordered` style with `theme.textSecondary` tint
- Count text uses `.monospaced` font, `theme.textPrimary`
- Animated number change when tapping +/−

```swift
private var loopRow: some View {
    HStack(spacing: 10) {
        Text("Repeats:")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(theme.textSecondary)
        Button { loopCount = max(1, loopCount - 1) } label: {
            Image(systemName: "minus.circle.fill").font(.system(size: 16))
        }
        .buttonStyle(.plain).foregroundStyle(theme.textSecondary)
        .disabled(loopCount <= 1)
        Text("\(loopCount)")
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .foregroundStyle(theme.textPrimary)
            .frame(width: 24)
        Button { loopCount = min(8, loopCount + 1) } label: {
            Image(systemName: "plus.circle.fill").font(.system(size: 16))
        }
        .buttonStyle(.plain).foregroundStyle(theme.textSecondary)
        .disabled(loopCount >= 8)
    }
}
```

---

## Phase 5: Drop Zone Polish

### 5a. Browse button

Add an "Or browse" button below the drop text that opens `NSOpenPanel`:

```swift
Button("Browse") {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
        loadVideo(url)
    }
}
.buttonStyle(.bordered)
.tint(theme.textSecondary)
```

### 5b. Drag-over highlight

Add `@State private var isDragOver = false`:

```swift
.onDrop(of: [.fileURL], isTargeted: $isDragOver) { ... }
```

Visual changes when `isDragOver`:
- Border color: `theme.dotActive` (full opacity)
- Scale: 1.02 with spring animation
- Background: `theme.dotActive.opacity(0.05)`

```swift
.stroke(
    isDragOver ? theme.dotActive : theme.dotActive.opacity(0.4),
    style: StrokeStyle(lineWidth: isDragOver ? 3 : 2, dash: [8, 6])
)
.scaleEffect(isDragOver ? 1.02 : 1.0)
.animation(.snappy, value: isDragOver)
```

### 5c. Transition animation

When video loads, animate from drop zone to editor:

```swift
if sourceURL != nil {
    editor.transition(.asymmetric(
        insertion: .move(edge: .bottom).combined(with: .opacity),
        removal: .opacity
    ))
} else {
    dropZone
}
.animation(.smooth, value: sourceURL != nil)
```

---

## Phase 6: Control Grouping

Restructure the editor's vertical stack into visually distinct sections.

### New editor layout:

```
videoPlayer
timeRow (slider + readout)
─── SECTION: Frame ───
markControls
filmStrip
zoomToggle
─── SECTION: Rhythm ───
presetRow
loopRow
─── SECTION: Precision ───
nudgeRow
─── SECTION: Export ───
exportRow
```

### Section styling

Each section gets a subtle separator — a thin horizontal line at 6% opacity:

```swift
Divider()
    .background(theme.textSecondary.opacity(0.06))
    .padding(.horizontal, 20)
```

The section labels are optional but help scanability. Only show them if the view is wide enough (>500pt):

```swift
HStack {
    Text("FRAME").font(.system(size: 9, weight: .medium, design: .rounded))
        .foregroundStyle(theme.textSecondary.opacity(0.5))
    Spacer()
}
```

---

## Phase 7: Export Toast Feedback

Replace the plain `Text(error)` / `Text(msg)` with animated toast capsules.

### State

```swift
@State private var toast: ToastMessage?

struct ToastMessage {
    let text: String
    let isError: Bool
}
```

### Toast view

```swift
private var toastOverlay: some View {
    Group {
        if let toast {
            HStack(spacing: 6) {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                Text(toast.text)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .foregroundStyle(toast.isError ? .red : .green)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(.ultraThinMaterial))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
    .animation(.snappy, value: toast != nil)
}
```

### Auto-dismiss

```swift
private func showToast(_ text: String, isError: Bool) {
    toast = ToastMessage(text: text, isError: isError)
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        if toast?.text == text { toast = nil }
    }
}
```

Place `.overlay(alignment: .bottom) { toastOverlay }` on the editor card.

---

## Phase 8: Keyboard Shortcuts

Add `.onKeyPress` to the editor for power-user workflow.

| Key | Action |
|-----|--------|
| `Space` | Play / Pause |
| `Left` | Step frame backward |
| `Right` | Step frame forward |
| `[` | Nudge trim start −0.1s |
| `]` | Nudge trim start +0.1s |
| `I` | Mark In |
| `O` | Mark Out |
| `L` | Toggle loop preview |
| `⌘O` | Open file picker |
| `Esc` | Clear / exit zoom |

```swift
.onKeyPress(.space) { playPause(); return .handled }
.onKeyPress(.leftArrow) { stepFrame(by: -1); return .handled }
.onKeyPress(.rightArrow) { stepFrame(by: 1); return .handled }
.onKeyPress("i") { markIn(); return .handled }
.onKeyPress("o") { markOut(); return .handled }
.onKeyPress("l") { toggleLoopPreview(); return .handled }
.onKeyPress("[") { nudgeTrimStart(-0.1); return .handled }
.onKeyPress("]") { nudgeTrimStart(0.1); return .handled }
```

Also add `playPause()` helper:

```swift
private func playPause() {
    guard let player else { return }
    if isPlaying {
        player.pause(); isPlaying = false; stopPlaybackTimer()
    } else {
        player.play(); isPlaying = true; startPlaybackTimer()
    }
}
```

---

## Phase 9: FilmstripBar Polish

### 9a. Wider edge handles

The current `handleWidth` (18pt) is only used for the hit area but the visible marker is 3px. Add invisible hit areas:

```swift
// Invisible wider handle for left edge
Rectangle()
    .fill(.clear)
    .frame(width: 16, height: h)
    .position(x: sx, y: h / 2)
    .contentShape(Rectangle())
    .gesture(leftHandleDrag)
```

### 9b. Duration label in selection band

When the selection band is wide enough (>60px), show the duration text inside:

```swift
if (ex - sx) > 60 {
    Text(String(format: "%.1fs", trimEnd - trimStart))
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .foregroundStyle(theme.dotActive)
        .position(x: (sx + ex) / 2, y: h / 2)
}
```

### 9c. Triangle playhead

Replace the rectangle playhead with a small triangle for better visibility:

```swift
// Playhead triangle
Path { path in
    path.move(to: CGPoint(x: px - 5, y: 0))
    path.addLine(to: CGPoint(x: px + 5, y: 0))
    path.addLine(to: CGPoint(x: px, y: 8))
    path.closeSubpath()
}
.fill(.white)
.position(x: 0, y: h + 2)
.shadow(color: .black.opacity(0.7), radius: 2)
```

---

## File Changes Summary

| File | What Changes |
|------|-------------|
| `CellaMotionsView.swift` | Major rewrite: remove Slider, add timeRow, add zoom toggle, add loopRow, add nudgeTrimEnd wiring, add drop zone polish, add toast overlay, add keyboard shortcuts, restructure editor into sections, improve FilmstripBar |
| `BoomerangMaker.swift` | No changes |
| `FilmstripGenerator.swift` | No changes (existing API handles zoom thumbnails) |

---

## Estimated Line Count Change

Current: 707 lines
Estimated: ~900–950 lines (add ~200–250 lines for new features, remove ~50 from Slider cleanup)

---

## Implementation Order

1. Phase 1 (bug fixes) — smallest, zero risk
2. Phase 2 (time readout) — visual improvement, moderate scope
3. Phase 4 (loop count) — small, independent
4. Phase 5 (drop zone) — small, independent
5. Phase 7 (toast feedback) — small, independent
6. Phase 9 (filmstrip polish) — small, independent
7. Phase 6 (control grouping) — restructure, depends on 2+4
8. Phase 3 (zoom) — largest change, depends on 9
9. Phase 8 (keyboard) — final polish, depends on all functions existing

Phases 4, 5, 7, 9 can be done in parallel.
