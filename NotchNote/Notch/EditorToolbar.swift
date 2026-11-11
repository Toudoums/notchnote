import SwiftUI

/// Formatting bar at the bottom of the Notes page: text style, font, line type and chips.
struct EditorToolbar: View {
    let displayID: CGDirectDisplayID
    @ObservedObject private var store = TaskStore.shared

    private var editor: EditorTextView? { NotchController.shared.editor(for: displayID) }

    var body: some View {
        HStack(spacing: 1) {
            tool("bold", "Bold (\u{2318}B)") { editor?.toggleInline("**", "**") }
            tool("italic", "Italic (\u{2318}I)") { editor?.toggleInline("*", "*") }
            tool("underline", "Underline (\u{2318}U)") { editor?.toggleInline("<u>", "</u>") }
            tool("strikethrough", "Strikethrough") { editor?.toggleInline("~~", "~~") }
            tool("highlighter", "Highlight") { editor?.toggleInline("==", "==") }
            fontMenu
            divider
            tool("textformat.size", "Heading") { editor?.toggleLineKind(MarkdownCodec.togglingHeading) }
            tool("list.bullet", "Bullet list (\u{21E7}\u{2318}B)") { editor?.toggleLineKind(MarkdownCodec.togglingBullet) }
            tool("checklist", "Checklist (\u{21E7}\u{2318}L)") { editor?.toggleLineKind(MarkdownCodec.togglingChecklist) }
            divider
            chipMenu
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 14).padding(.horizontal, 4)
    }

    private func tool(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5)).frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var fontMenu: some View {
        Menu {
            Button("Sans") { editor?.setFontTag(nil) }
            Button("Book (serif)") { editor?.setFontTag("book") }
            Button("Mono") { editor?.setFontTag("mono") }
            Button("Rounded") { editor?.setFontTag("round") }
            Divider()
            Button("Clear formatting") { editor?.clearFormatting() }
        } label: {
            Text("Aa").font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30, height: 24)
        .help("Font for the selected text")
    }

    // MARK: Chips

    private var allBodies: String { store.tasks.map(\.body).joined(separator: "\n") }

    private func put(_ kind: ChipKind, _ value: String) {
        editor?.insertChip(ChipToken(kind: kind, value: value))
    }

    private func reminder(inMinutes m: Int? = nil, hour: Int? = nil, tomorrow: Bool = false) -> String {
        let cal = Calendar.current
        var date = Date()
        if let m { date = date.addingTimeInterval(Double(m) * 60) }
        if let hour {
            date = cal.date(bySettingHour: hour, minute: 0, second: 0, of: tomorrow ? cal.date(byAdding: .day, value: 1, to: date) ?? date : date) ?? date
        }
        return ChipToken.isoFormat.string(from: date)
    }

    private var chipMenu: some View {
        Menu {
            Menu("Date") {
                Button("Today") { editor?.insertChip(.day(0)) }
                Button("Tomorrow") { editor?.insertChip(.day(1)) }
                Button("Next week") { editor?.insertChip(.day(7)) }
            }
            Menu("Reminder") {
                Button("In 15 minutes") { put(.rem, reminder(inMinutes: 15)) }
                Button("In 1 hour") { put(.rem, reminder(inMinutes: 60)) }
                Button("This evening 18:00") { put(.rem, reminder(hour: 18)) }
                Button("Tomorrow 09:00") { put(.rem, reminder(hour: 9, tomorrow: true)) }
            }
            Menu("Priority") {
                Button("High (p1)") { put(.prio, "h") }
                Button("Medium (p2)") { put(.prio, "m") }
                Button("Low (p3)") { put(.prio, "l") }
            }
            Menu("Tag") {
                ForEach(AppSettings.shared.allTags(in: store.tasks), id: \.self) { t in
                    Button("#" + t) { put(.tag, t) }
                }
            }
            Menu("Person") {
                let people = ChipToken.values(of: .person, in: allBodies)
                if people.isEmpty { Text("Type @name and a space") }
                ForEach(people, id: \.self) { p in Button("@" + p) { put(.person, p) } }
            }
            Menu("Time estimate") {
                ForEach([15, 30, 45, 60, 120], id: \.self) { m in
                    Button(m >= 60 ? "\(m / 60) hour\(m > 60 ? "s" : "")" : "\(m) minutes") { put(.est, String(m)) }
                }
            }
            Menu("Repeat") {
                ForEach(["Daily", "Weekdays", "Weekly", "Monthly"], id: \.self) { r in Button(r) { put(.rep, r) } }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tag").font(.system(size: 11))
                Text("Chip").font(.system(size: 11.5, weight: .semibold))
            }
            .padding(.horizontal, 8).frame(height: 22)
            .background(Capsule().fill(Color.white.opacity(0.14)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Insert a chip. You can also type today, p1, #tag, @person or 30m followed by a space.")
    }
}
