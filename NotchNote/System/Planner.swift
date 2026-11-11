import Foundation

/// One checklist line, read from a note, as the Today page sees it.
struct PlanItem: Identifiable, Equatable {
    var id: String { "\(taskID.uuidString)-\(lineIndex)" }
    let taskID: UUID
    let taskTitle: String
    let lineIndex: Int
    let text: String
    let checked: Bool
    let minutes: Int
    let priority: String?
    let tags: [String]
    let dateValue: String?

    var isToday: Bool {
        guard let d = dateValue else { return false }
        return d == "today" || d == ChipToken.dayFormat.string(from: Date())
    }
    var hasDate: Bool { dateValue != nil }
}

/// Reads and edits checklist lines across all notes. Edits go through TaskStore, so autosave,
/// Spotlight and sync all keep working.
@MainActor
enum Planner {
    private static let itemRegex = try! NSRegularExpression(pattern: "^(\\s*)- \\[( |x|X)\\] (.*)$")

    static func items(from tasks: [NoteTask]) -> [PlanItem] {
        var out: [PlanItem] = []
        for t in tasks {
            let lines = t.body.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let ns = line as NSString
                guard let m = itemRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
                let checked = ns.substring(with: m.range(at: 2)).lowercased() == "x"
                let content = ns.substring(with: m.range(at: 3))
                var minutes = 0
                var prio: String?
                var tags: [String] = []
                var date: String?
                let cns = content as NSString
                for c in ChipToken.regex.matches(in: content, range: NSRange(location: 0, length: cns.length)) {
                    let kind = cns.substring(with: c.range(at: 1))
                    let value = cns.substring(with: c.range(at: 2))
                    switch kind {
                    case "est": minutes = Int(value) ?? 0
                    case "prio": prio = value
                    case "tag": tags.append(value)
                    case "date": date = value
                    default: break
                    }
                }
                let text = MarkdownCodec.stripInline(content)
                if text.isEmpty && minutes == 0 { continue }
                out.append(PlanItem(taskID: t.id, taskTitle: t.title, lineIndex: i, text: text, checked: checked,
                                    minutes: minutes, priority: prio, tags: tags, dateValue: date))
            }
        }
        return out
    }

    private static func edit(_ item: PlanItem, _ f: (String) -> String) {
        TaskStore.shared.update(item.taskID) { t in
            var lines = t.body.components(separatedBy: "\n")
            guard item.lineIndex < lines.count else { return }
            lines[item.lineIndex] = f(lines[item.lineIndex])
            t.body = lines.joined(separator: "\n")
        }
    }

    static func toggle(_ item: PlanItem) {
        edit(item) { line in
            if item.checked { return line.replacingOccurrences(of: "- [x]", with: "- [ ]").replacingOccurrences(of: "- [X]", with: "- [ ]") }
            return line.replacingOccurrences(of: "- [ ]", with: "- [x]")
        }
    }

    static func moveToTomorrow(_ item: PlanItem) {
        let today = ChipToken.dayFormat.string(from: Date())
        edit(item) { line in
            line.replacingOccurrences(of: "[[date:today]]", with: ChipToken.day(1).token)
                .replacingOccurrences(of: "[[date:\(today)]]", with: ChipToken.day(1).token)
        }
    }

    static func planForToday(_ item: PlanItem) {
        edit(item) { $0 + " " + ChipToken.day(0).token }
    }

    /// Adds "text p1 30m #tag" as a new checklist line dated today, in the open note (or the first note).
    static func addToday(_ raw: String) {
        let store = TaskStore.shared
        var words: [String] = []
        var chips: [String] = []
        for w in raw.split(separator: " ") {
            let word = String(w)
            if word.lowercased() == "today" || word.lowercased() == "#today" { continue }
            if let c = ChipToken.parseQuick(word) { chips.append(c.token) } else { words.append(word) }
        }
        guard !words.isEmpty else { return }
        let line = "- [ ] " + words.joined(separator: " ") + " " + ChipToken.day(0).token + (chips.isEmpty ? "" : " " + chips.joined(separator: " "))
        let target = store.selectedTask ?? store.tasks.first ?? store.createTask(title: "Inbox", select: false)
        store.update(target.id) { t in
            t.body = t.body.isEmpty ? line : (t.body.hasSuffix("\n") ? t.body + line : t.body + "\n" + line)
        }
    }
}
