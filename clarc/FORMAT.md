# CLARC format draft

CLARC is a readable, line-oriented lyric format inspired by LRC. Version 1
keeps LRC's familiar timestamp notation and uses the surrounding structure to
identify the format and organize metadata.

For a step-by-step conversion from LRC, see [MIGRATING_FROM_LRC.md](MIGRATING_FROM_LRC.md).

## Example

```text
CLARC/1

[metadata]
title: Trễ Giờ Cơm
artist.1: Quang Hùng MasterD
artist.2: Xuân Định K.Y
artist.3: WEAN
artist.4: Sơn.K
writer: Trịnh Thăng Bình
album: TINH HÀ "SAY HI", TẬP 13
duration: 05:08

[lyrics]
[00:00.00] …
[00:01.12] (Hino in your mind)
[00:19.46] [v1] Khi xưa tan trường
[01:13.27] [v2] Bàn chân cứ bước đi giữa đất trời [DUO] Vượt qua những trùng khơi
[01:27.29] [v1&v2] Là có mẹ, có cha, có chúng ta
[01:27.29] Là có mẹ, có cha, có chúng ta
[har 01:28.00] (Ah-ah)
[har 01:29.00] (Ooh-ooh-ooh-ooh-ooh)
```

## Version 1 rules

- A file is UTF-8 text. The first non-empty line is exactly `CLARC/1`.
- `[metadata]` begins the song metadata section. `[lyrics]` ends it and begins
  the lyric events section. Both section headers are required and must appear
  in this order.
- Metadata lines appear only in the `[metadata]` section and use `key: value`.
- `title`, `writer`, `album`, `duration`, and indexed `artist.N` keys are
  recognized metadata. `writer` identifies the songwriter or songwriters.
  Artist entries are optional. When used for vocal attribution, artist indexes
  are positive integers; for example, `artist.1` identifies vocalist `v1`,
  and `artist.2` identifies vocalist `v2`.
- A metadata value is plain text after the first colon; surrounding whitespace
  is trimmed. Quotes and punctuation in the value are literal, not escapes.
- `duration`, when present, uses the `mm:ss` format.
- Timed lyric and harmony lines appear only in the `[lyrics]` section.
- A lyric line has the form `[mm:ss.xx] lyric text`, where `mm` is the
  non-negative minute count, `ss` is `00` through `59`, and `xx` is `00`
  through `99` hundredths of a second.
- Vocalist markers are optional on every lyric line. When present, a marker
  such as `[v1]` or `[v1&v2]` follows the timestamp. Each vocalist ID maps to
  the correspondingly numbered `artist.N` metadata entry. Multiple IDs joined
  by `&` indicate that those artists sing the line together. The marker is
  attribution metadata, not displayed lyric text.
- A plain `artist: Name` entry acts as `artist.1`. Single-artist files may
  use either form; writers emit `artist.N` for consistency.
- A lyric timestamp represents time from the start of the audio. Timestamps
  must be in non-decreasing order. Equal timestamps are allowed for
  simultaneous lines.
- Lyric text is everything after the timestamp and optional vocalist marker,
  preserving spaces and Unicode. An empty lyric is allowed. Blank lines are
  ignored.
- `[DUO]` within lyric text is a layout marker: text before it is left-aligned
  and text after it is right-aligned on the same display row. It is not a
  speaker label. A line may contain at most one `[DUO]`.
- A harmony line has the form `[har mm:ss.xx] lyric text`. It marks a timed
  backing-vocal or harmony part and follows the same timestamp ordering rule
  as lyric lines.
- Unknown metadata keys should be preserved by tools that read and write CLARC.
  Duplicate metadata keys are invalid.

## Reader and writer behavior (reference implementation)

The reader and writer in the Cella app (`Cella/Utilities/ClarcParser.swift`)
define the practical behavior of CLARC/1 today:

- **Tolerant reading.** Malformed event lines are skipped rather than failing
  the file. Timestamps are re-sorted into non-decreasing order on read, so a
  hand-edited out-of-order file plays correctly. Fraction digits other than
  exact two (`.5`, `.123`) are accepted and padded to milliseconds.
- **Duplicate metadata.** Duplicates are invalid per the rules above; if they
  occur, the reader resolves them last-wins instead of erroring. Recognized
  key matching is case-insensitive.
- **Legacy rescue.** An old writer bug could emit a classic LRC banner
  (`[ti:…]`, `[ar:…]`) before the `CLARC/1` marker. When every line before the
  marker is blank or a `[word:…]` tag, the reader skips the banner and parses
  normally, healing such files on their next read.
- **Canonical write order.** The writer emits `title`, then `artist.N` entries
  in ascending index order, then `writer`, `album`, `duration`, followed by any
  preserved unknown keys. Timestamps are written as two-digit hundredths
  (`[MM:SS.xx]`), harmony rows keep their `har` prefix inside the brackets, and
  vocalist markers are re-emitted between the timestamp and the text. Metadata
  values are flattened: embedded CR/LF is folded to spaces. The file ends with
  a trailing newline.

## Why this first version

- Existing LRC timestamps remain easy to read and convert without changing
  their timing notation.
- A format marker lets readers reject unsupported versions rather than
  guessing.
- The metadata section separates song information from the timed lyric events.

## Not in version 1

Word-level timing, translations, speaker labels, styling, and synchronization
semantics beyond line start times are intentionally not defined yet. They are
good candidates for a later version, once the basic format and conversion
behavior are agreed on.

## Chronological ordering

Timed lyric and harmony lines must be listed in non-decreasing timestamp order.
For example, this is invalid because the second line goes backward in time:

```text
[01:30.00] Previous Lyric line
[01:27.29] Là có mẹ, có cha, có chúng ta (Ooh-ooh-ooh-ooh-ooh)
[01:30.00] Next Lyric line
```

Put the lyric and backing-vocal events in chronological order instead:

```text
[01:27.29] Là có mẹ, có cha, có chúng ta
[har 01:28.00] (Ah-ah)
[har 01:29.00] (Ooh-ooh-ooh-ooh-ooh)

[01:30.00] Previous Lyric line
[01:30.00] Next Lyric line
```
