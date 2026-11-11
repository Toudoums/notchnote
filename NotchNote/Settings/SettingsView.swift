import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = TaskStore.shared
    @State private var loginError: String?
    @State private var newTag = ""
    @State private var newTagGroup: UUID?
    @State private var newTagColor = Color(nsColor: ChipKind.tag.fill.withAlphaComponent(1))
    @State private var newGroup = ""
    @State private var tagToDelete: String?

    private let intervals: [(String, Int)] = [("Off", 0), ("Every 5 minutes", 5), ("Every 15 minutes", 15), ("Every 30 minutes", 30),
                                              ("Every hour", 60), ("Every 2 hours", 120), ("Every 4 hours", 240)]

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLoginEnabled },
                    set: { on in
                        do { try settings.setLaunchAtLogin(on); loginError = nil }
                        catch { loginError = error.localizedDescription }
                    }))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Text("NotchNote runs in the background with no Dock icon and starts at login. Quit it from the menu bar icon. Launch at login works best once it is in /Applications.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show Getting Started\u{2026}") { WindowManager.shared.showOnboarding() }
            }

            Section("Reminders") {
                Picker("Remind me about unchecked items", selection: $settings.reminderIntervalMinutes) {
                    ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
                }
                Text("Reminders pause while your Mac is locked, asleep or in screen saver, and restart when it is ready.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Send a test reminder now") { ReminderService.shared.sendNow() }
            }

            Section("Planning") {
                Picker("Daily workload limit", selection: $settings.dailyLimitHours) {
                    ForEach([2, 3, 4, 6, 8], id: \.self) { Text("\($0) hours").tag($0) }
                }
                Picker("Focus session length", selection: $settings.focusMinutes) {
                    ForEach([10, 15, 25, 30, 45, 50, 60, 90], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Text("Today adds up the time estimates of what you planned and warns when it passes your limit.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            tagsSection

            Section("Sync folder") {
                HStack {
                    Text(settings.syncFolderPath ?? "Not set (tasks stay on this Mac)")
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(settings.syncFolderPath == nil ? .secondary : .primary)
                    Spacer()
                    Button("Choose\u{2026}") { chooseFolder() }
                    if settings.syncFolderPath != nil {
                        Button("Clear") { settings.syncFolderPath = nil }
                    }
                }
                Text("Pick a folder inside iCloud Drive (or Dropbox, Syncthing\u{2026}) to sync tasks across your Macs. Move individual tasks in or out from the task window\u{2019}s context menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Toggle("Hide the notch when an app or a web page is full screen", isOn: $settings.hideInFullScreen)
                Picker("Display without a notch", selection: $settings.externalStyleRaw) {
                    ForEach(ExternalStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Move checked items to the bottom of the list", isOn: $settings.sortCheckedToBottom)
                ColorPicker("Text color", selection: Binding(
                    get: { settings.textColor },
                    set: { settings.textColorHex = NSColor($0).hexString }))
                HStack {
                    Text("Notch width")
                    Slider(value: $settings.notchExtraWidth, in: -40...160)
                    Text("\(Int(settings.notchExtraWidth)) pt").monospacedDigit().frame(width: 56, alignment: .trailing)
                }
                HStack {
                    Text("Notch height")
                    Slider(value: $settings.notchExtraHeight, in: -4...30)
                    Text("\(Int(settings.notchExtraHeight)) pt").monospacedDigit().frame(width: 56, alignment: .trailing)
                }
                HStack {
                    Text("Panel width")
                    Slider(value: $settings.panelWidth, in: AppSettings.panelWidthRange)
                    Text("\(Int(settings.panelWidth)) pt").monospacedDigit().frame(width: 56, alignment: .trailing)
                }
                HStack {
                    Text("Panel height")
                    Slider(value: $settings.panelHeight, in: AppSettings.panelHeightRange)
                    Text("\(Int(settings.panelHeight)) pt").monospacedDigit().frame(width: 56, alignment: .trailing)
                }
                HStack {
                    Spacer()
                    Button("Reset size") {
                        settings.resetPanelSize()
                        settings.notchExtraWidth = 0
                        settings.notchExtraHeight = 0
                    }
                }
                Text("You can also resize the panel by dragging the handle in its bottom-right corner.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle("Share anonymous usage data", isOn: $settings.usageDataEnabled)
                Text("Off by default. NotchNote contains no networking code, so no data is sent whether this is on or off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { tagToDelete != nil }, set: { if !$0 { tagToDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let t = tagToDelete {
                    store.removeTagEverywhere(t)
                    settings.forgetTag(t)
                }
                tagToDelete = nil
            }
            Button("Cancel", role: .cancel) { tagToDelete = nil }
        } message: {
            if let t = tagToDelete, store.notesUsing(tag: t) > 0 {
                Text("#\(t) will also be removed from \(store.notesUsing(tag: t)) note(s).")
            }
        }
    }

    // MARK: Tags

    private var deleteTitle: String { "Delete #\(tagToDelete ?? "")?" }

    private var allTags: [String] { settings.allTags(in: store.tasks) }
    private var ungroupedTags: [String] { allTags.filter { settings.group(of: $0) == nil } }

    private var tagsSection: some View {
        Section("Tags") {
            HStack(spacing: 8) {
                TextField("", text: $newTag, prompt: Text("New tag name"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTag)
                ColorPicker("", selection: $newTagColor, supportsOpacity: false).labelsHidden()
                Picker("", selection: $newTagGroup) {
                    Text("No group").tag(UUID?.none)
                    ForEach(settings.tagGroups) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .labelsHidden().frame(width: 120)
                Button("Add tag", action: addTag).disabled(AppSettings.normalizeTag(newTag) == nil)
            }
            HStack(spacing: 8) {
                TextField("", text: $newGroup, prompt: Text("New group name"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addGroup)
                Button("Add group", action: addGroup)
                    .disabled(newGroup.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            ForEach(settings.tagGroups) { g in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    TextField("", text: Binding(get: { g.name }, set: { settings.renameGroup(g.id, $0) }), prompt: Text("Group name"))
                        .labelsHidden()
                        .textFieldStyle(.plain).fontWeight(.semibold)
                        .help("Click to rename the group")
                    Spacer()
                    Button { settings.deleteGroup(g.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete this group. Its tags are kept, without a group.")
                }
                if g.tags.isEmpty {
                    Text("No tags yet").font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
                }
                ForEach(g.tags, id: \.self) { tagRow($0) }
            }

            if !ungroupedTags.isEmpty {
                Text(settings.tagGroups.isEmpty ? "Tags" : "No group").font(.caption).foregroundStyle(.secondary)
                ForEach(ungroupedTags, id: \.self) { tagRow($0) }
            }

            Text("Type # in a note to pick a tag from this list. #today and #tomorrow are date tags: they update by themselves (Tomorrow, then Today, then \u{201C}2 days late\u{201D}).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func tagRow(_ t: String) -> some View {
        HStack {
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: AppSettings.storedTagColor(t) ?? ChipKind.tag.fill.withAlphaComponent(1)) },
                set: { settings.tagColors[t] = NSColor($0).hexString }), supportsOpacity: false)
                .labelsHidden()
                .padding(.leading, 16)
                .help("Tag color")
            Text("#" + t)
            let n = store.notesUsing(tag: t)
            if n > 0 { Text("\(n) note\(n == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Picker("", selection: Binding(get: { settings.group(of: t)?.id }, set: { settings.moveTag(t, to: $0) })) {
                Text("No group").tag(UUID?.none)
                ForEach(settings.tagGroups) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            .labelsHidden().frame(width: 130)
            Button { tagToDelete = t } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete this tag")
        }
    }

    private func addTag() {
        guard let t = AppSettings.normalizeTag(newTag) else { return }
        settings.addTag(t, group: newTagGroup)
        settings.tagColors[t] = NSColor(newTagColor).hexString
        newTag = ""
    }

    private func addGroup() {
        settings.addGroup(newGroup)
        newGroup = ""
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder NotchNote should sync tasks into (for example a folder in iCloud Drive)."
        if panel.runModal() == .OK, let url = panel.url { settings.syncFolderPath = url.path }
    }
}
