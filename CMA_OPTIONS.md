# CMA (Cella Motion Artworks)

## Make the moment move twice

CMA is Cella's Boomerang-style motion editor: choose a small piece of video, play it forward, send it back, and repeat it until the motion feels right.

The result is a `.cma` file: an H.264 MP4 used as a visual asset beside a music track.

The source video may be anywhere from **3 minutes to 50 minutes**, so the editor should make navigation quick at the whole-video level and precise at the selected-moment level.

## The editor

### 1. Drop a clip

Drop an **MP4** or **MOV** into the Cella Motions editor. The filmstrip becomes your timeline, with the full source duration visible so you always know where you are.

For long videos, use two levels of navigation:

- **Overview:** the full-width filmstrip shows the entire source. Tap or drag anywhere to jump quickly through a 3–50 minute video.
- **Detail:** zoom into the area around the selection before making fine adjustments. The selected region should remain visible while the surrounding timeline provides context.

Always show the current playhead time and total duration, for example `18:42 / 42:10`. This makes a location easy to find again and prevents confusing a short selection with the length of the source.

### 2. Find the moment quickly

Use a coarse-to-fine pass instead of dragging frame by frame from the start:

1. Tap the approximate location on the overview filmstrip.
2. Drag the selection band until the right action is centered.
3. Zoom into the selection for accurate trimming.
4. Use the frame controls only for the final adjustment.

The playhead should stay visible after every jump. A selected band must remain stable while the timeline zooms, so zooming never changes the clip boundaries.

### 3. Choose the rhythm

Use the **Length** row to pick the loop's personality:

| Length | Feel |
| --- | --- |
| **0.3s** | Fast, punchy, glitch-like |
| **0.5s** | Quick and playful |
| **1.0s** | Classic Boomerang motion; default |
| **2.0s** | More room for a gesture or reveal |

### 4. Frame the action

- **Mark In** sets the clip start at the current playhead.
- **Mark Out** sets the clip end at the current playhead.
- **Filmstrip tap** jumps to a broad location in the source.
- **Filmstrip drag** scrubs around the current location.
- **Selection band drag** moves the entire highlighted clip without changing its length.

When the selection is moved, preserve its duration and keep both boundaries on screen. This is the safest way to reposition a short Boomerang inside a long recording.

### 5. Find the perfect beat

Use the fine-tune buttons when the motion is almost there:

| Control | What it does |
| --- | --- |
| `<< 0.1` / `0.1 >>` | Nudge the trim start by 0.1 seconds |
| `< frame` / `frame >` | Step backward or forward by one frame |

Use the 0.1-second controls for normal adjustment and the frame controls only when the turnaround needs exact timing. Show the selected start and end times beside the controls when space allows.

### 6. Watch it bounce

Turn on **Loop Preview** to watch the selected clip continuously play forward and backward. Look for a clean turnaround: the best loops feel like one fluid gesture, not a restart.

### 7. Set the repeats

**Loop Count** controls how many forward-and-backward cycles are exported. The default is **3**.

- More loops create a longer, more hypnotic visual.
- Fewer loops keep the result short and snappy.

## Recommended long-video workflow

1. Drop an MP4 or MOV into the Cella Motions drop zone.
2. Confirm the source duration and locate the rough moment on the overview filmstrip.
3. Move the selection band to center the action without changing its duration.
4. Zoom into the selected area.
5. Choose a length: **0.3s**, **0.5s**, **1.0s**, or **2.0s**.
6. Set the boundaries with **Mark In** and **Mark Out**.
7. Nudge by 0.1 seconds or one frame until the motion lands cleanly.
8. Enable **Loop Preview** and check the turnaround.
9. Choose the loop count.
10. Select **Create Boomerang**.

The export is saved beside the source as `<filename>.cma`.

### Adjustment rules

- Do not require users to scrub through the entire source to reach a late timestamp.
- Keep overview navigation and precise trimming visually distinct.
- Keep the selected duration fixed when the selection band is moved.
- Keep the playhead, selection boundaries, current time, and total duration readable at every zoom level.
- Restore the previous location when switching between overview and detail views.

### After export

- **Show in Finder** opens the exported file's location.
- **Clear** resets the editor so you can drop in another source clip.

## Where CMA files live

```text
MusicLibrary/
└── cma/
    └── <Artist>/
        ├── TrackName.cma
        └── ...
```

Cella matches CMA files to tracks by artist name using NFD normalization, title case, and hyphen/underscore variants.

## Export contract

- **Extension:** `.cma`
- **Container:** MP4
- **Codec:** H.264
- **Pixel format:** 32BGRA
- **Timescale:** 60000 for high-precision trimming
- **Playback:** forward frames followed by reversed frames, repeated `loopCount` times
- **Trimming:** `AVAssetExportSession` with the highest-quality preset
