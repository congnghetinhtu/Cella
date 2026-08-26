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
    }
}
