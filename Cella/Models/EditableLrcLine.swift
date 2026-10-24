import Foundation

struct EditableLrcLine: Identifiable {
    let id = UUID()
    var time: TimeInterval
    var text: String
    var isEditing: Bool = false

    var timestampString: String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let fraction = Int((time - Double(Int(time))) * 100)
        return String(format: "%02d:%02d.%02d", minutes, seconds, fraction)
    }

    init(time: TimeInterval = 0, text: String = "", isEditing: Bool = false) {
        self.time = time
        self.text = text
        self.isEditing = isEditing
    }

    init(from line: LrcLine) {
        self.time = line.time
        self.text = line.text
        self.vocalists = line.vocalists
        self.isHarmony = line.isHarmony
        self.duoLead = line.duoLead
        self.duoTail = line.duoTail
    }

    /// CLARC vocalist attribution (artist.N numbers) — [] = no mark.
    var vocalists: [Int] = []
    /// Harmony row ([har]) — timed backing part, no vocalist chips.
    var isHarmony: Bool = false

    /// CLARC `[DUO]` layout split (see LrcLine) — display halves for the
    /// left/right anchored row. Empty when the row is a plain line.
    var duoLead: String = ""
    var duoTail: String = ""
    var isDuo: Bool { !(duoLead.isEmpty && duoTail.isEmpty) }

    /// Line → raw LrcLine carrying attribution, harmony flags and the
    /// `[DUO]` split (for CLARC save/compose). The .lrc export branch
    /// ignores those on purpose.
    var asLrcLine: LrcLine {
        LrcLine(
            time: time,
            text: text,
            vocalists: vocalists,
            isHarmony: isHarmony,
            duoLead: duoLead,
            duoTail: duoTail)
    }

    /// The row's editable raw form. Duo rows open with the literal
    /// `lead [DUO] tail` so the split stays visible while editing, the
    /// marker can be moved to nudge the split, and deleting it folds the
    /// row back to a plain line — `apply(text:)` re-splits on submit.
    var rawEditText: String {
        guard isDuo, !(duoLead.isEmpty && duoTail.isEmpty) else { return text }
        if duoLead.isEmpty { return "[DUO]" + (duoTail.isEmpty ? "" : " " + duoTail) }
        return duoLead + " [DUO]" + (duoTail.isEmpty ? "" : " " + duoTail)
    }

    /// Editor text → row. A literal `[DUO]` in the typed text sets the
    /// left/right split (the round-trip marker for CLARC saves); removing
    /// the marker turns the row back into a plain line. Extra markers are
    /// honored once and kept literal after — spec allows at most one.
    mutating func apply(text: String) {
        let marker = "[DUO]"
        if let range = text.range(of: marker) {
            let lead = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let tail = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            duoLead = lead
            duoTail = tail
            self.text = lead.isEmpty ? tail : (tail.isEmpty ? lead : lead + " " + tail)
        } else {
            duoLead = ""
            duoTail = ""
            self.text = text
        }
    }
}
