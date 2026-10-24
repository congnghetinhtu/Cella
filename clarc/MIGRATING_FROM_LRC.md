# Migrating from LRC to CLARC

CLARC keeps LRC's familiar `[mm:ss.xx]` lyric timestamps. Conversion mainly
means moving song information into a metadata section and lyrics into a
separate lyrics section. Cella's reader also repairs small mistakes — it
re-sorts timestamps that went out of order and preserves unknown metadata —
but get the conversion right the first time and the file round-trips clean.

## Basic conversion

1. Start the file with `CLARC/1`.
2. Add `[metadata]` and move LRC song tags into `key: value` entries.
3. Add `[lyrics]` and copy each timestamped lyric line, keeping its timestamp
   and text.
4. Check that timestamps are in non-decreasing order.

For example, convert this LRC:

```text
[ti:Trễ Giờ Cơm]
[ar:Quang Hùng MasterD & Xuân Định K.Y]
[al:TINH HÀ "SAY HI", TẬP 13]
[length:5:08]

[00:00.00]…
[00:19.46]Khi xưa tan trường
```

To this CLARC:

```text
CLARC/1

[metadata]
title: Trễ Giờ Cơm
artist.1: Quang Hùng MasterD
artist.2: Xuân Định K.Y
album: TINH HÀ "SAY HI", TẬP 13
duration: 05:08

[lyrics]
[00:00.00] …
[00:19.46] Khi xưa tan trường
```

## LRC tag mapping

| LRC tag | CLARC field | Notes |
| --- | --- | --- |
| `[ti:...]` | `title: ...` | Copy the value after the tag. |
| `[ar:...]` | `artist.N: ...` | Use one indexed entry per artist when known. A single-artist file may use plain `artist: ...`, which acts as `artist.1`. Artist entries and vocalist tags are optional. |
| `[al:...]` | `album: ...` | Keep punctuation and quotes as literal text; do not escape them. |
| `[au:...]` | `writer: ...` | Songwriter credit; keep it even when it matches the artist. |
| `[length:m:ss]` | `duration: mm:ss` | Zero-pad the minute and second fields if needed. |
| `[by:...]` or other descriptive tags | Same key in `[metadata]` | Preserve useful extra information as a plain `key: value` entry. |

Handle `[offset:...]` separately: apply the LRC offset to the lyric timestamps
according to the LRC file's convention, then omit the tag. CLARC does not
currently define an offset field; verify the converted timings against the
audio.

If an LRC artist tag contains multiple artists, split them into separate
`artist.N` entries when you know the individual names. If you do not know the
split, preserve the full credit as one entry rather than guessing.

## Timestamps and vocalist attribution

LRC lyric timestamps already use CLARC's `[mm:ss.xx]` notation, so keep them
unchanged. Add a space after the timestamp for readability. If an LRC uses
multiple timestamps for the same lyric text, make one CLARC line per timestamp.

Vocalist attribution is optional. When the singer is known and matches an
indexed artist entry, add its vocalist marker after the timestamp:

```text
[00:19.46] [v1] Khi xưa tan trường
[00:23.21] [v2] Cùng mấy đứa bạn thân đạp xe đi khắp nơi
[00:27.71] [v1&v2] Ngồi quán net đến hai giờ trưa
```

Here, `v1` maps to `artist.1`, and `v2` maps to `artist.2`. Do not infer
vocalist markers when the LRC does not identify who sings each line.

CLARC harmony lines use `[har mm:ss.xx]`; add them only when backing-vocal
timing is known. `[DUO]` is an optional layout marker for splitting a long
line into left- and right-aligned parts. Neither marker is required for a
basic LRC conversion.

## Review the converted file

- Confirm the `[metadata]` and `[lyrics]` sections are present and in order.
- Check that every timestamp remains attached to the correct lyric and that
  timestamps do not go backward.
- Preserve lyric spelling, punctuation, and Unicode text.
- Do not add guessed singer assignments, harmony timing, or `[DUO]` markers.
