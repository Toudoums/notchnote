import AppKit
import SwiftUI
import ServiceManagement

/// How the panel looks on a display without a notch.
enum ExternalStyle: String, CaseIterable, Identifiable {
    case glass, black, virtualNotch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: return "Glass pill"
        case .black: return "Black pill"
        case .virtualNotch: return "Virtual notch"
        }
    }
}

/// A named group of tags, managed in Settings.
struct TagGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var tags: [String]
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var syncFolderPath: String? { didSet { d.set(syncFolderPath, forKey: "syncFolderPath") } }
    /// 0 = reminders off
    @Published var reminderIntervalMinutes: Int { didSet { d.set(reminderIntervalMinutes, forKey: "reminderIntervalMinutes") } }
    @Published var textColorHex: String { didSet { d.set(textColorHex, forKey: "textColorHex") } }
    @Published var notchExtraWidth: Double { didSet { d.set(notchExtraWidth, forKey: "notchExtraWidth") } }
    @Published var notchExtraHeight: Double { didSet { d.set(notchExtraHeight, forKey: "notchExtraHeight") } }
    @Published var panelWidth: Double { didSet { d.set(panelWidth, forKey: "panelWidth") } }
    @Published var panelHeight: Double { didSet { d.set(panelHeight, forKey: "panelHeight") } }
    /// Optional anonymous usage data. Default OFF. Nothing is ever sent: there is no networking code
    /// in this app. The flag exists so the setting and its wording match the original app.
    @Published var usageDataEnabled: Bool { didSet { d.set(usageDataEnabled, forKey: "usageDataEnabled") } }
    @Published var dailyLimitHours: Int { didSet { d.set(dailyLimitHours, forKey: "dailyLimitHours") } }
    @Published var focusMinutes: Int { didSet { d.set(focusMinutes, forKey: "focusMinutes") } }
    @Published var folders: [String] { didSet { d.set(folders, forKey: "folders") } }
    @Published var externalStyleRaw: String { didSet { d.set(externalStyleRaw, forKey: "externalStyle") } }
    @Published var sortCheckedToBottom: Bool { didSet { d.set(sortCheckedToBottom, forKey: "sortCheckedToBottom") } }
    @Published var hasOnboarded: Bool { didSet { d.set(hasOnboarded, forKey: "hasOnboarded") } }
    @Published var lastSelectedTaskID: String? { didSet { d.set(lastSelectedTaskID, forKey: "lastSelectedTaskID") } }
    /// Tags added in Settings that are not in a group (tags used in notes are found automatically).
    @Published var savedTags: [String] { didSet { d.set(savedTags, forKey: "savedTags") } }
    /// Tag -> color hex ("#RRGGBB"). Tags without an entry use the default green.
    @Published var tagColors: [String: String] {
        didSet {
            d.set(tagColors, forKey: "tagColors")
            NotificationCenter.default.post(name: .chipStyleChanged, object: nil)
        }
    }
    /// Hide the notch on a display while an app or a web page is full screen there.
    @Published var hideInFullScreen: Bool { didSet { d.set(hideInFullScreen, forKey: "hideInFullScreen") } }
    @Published var tagGroups: [TagGroup] {
        didSet { d.set(try? JSONEncoder().encode(tagGroups), forKey: "tagGroups") }
    }

    nonisolated static let panelWidthRange: ClosedRange<Double> = 320...900
    nonisolated static let panelHeightRange: ClosedRange<Double> = 200...800

    private init() {
        let d = UserDefaults.standard
        syncFolderPath = d.string(forKey: "syncFolderPath")
        reminderIntervalMinutes = d.object(forKey: "reminderIntervalMinutes") as? Int ?? 30
        textColorHex = d.string(forKey: "textColorHex") ?? "#FFFFFF"
        notchExtraWidth = d.object(forKey: "notchExtraWidth") as? Double ?? 0
        notchExtraHeight = d.object(forKey: "notchExtraHeight") as? Double ?? 0
        panelWidth = d.object(forKey: "panelWidth") as? Double ?? 440
        panelHeight = d.object(forKey: "panelHeight") as? Double ?? 320
        usageDataEnabled = d.object(forKey: "usageDataEnabled") as? Bool ?? false
        dailyLimitHours = d.object(forKey: "dailyLimitHours") as? Int ?? 4
        focusMinutes = d.object(forKey: "focusMinutes") as? Int ?? 25
        folders = d.stringArray(forKey: "folders") ?? []
        externalStyleRaw = d.string(forKey: "externalStyle") ?? ExternalStyle.glass.rawValue
        sortCheckedToBottom = d.object(forKey: "sortCheckedToBottom") as? Bool ?? true
        hasOnboarded = d.object(forKey: "hasOnboarded") as? Bool ?? false
        lastSelectedTaskID = d.string(forKey: "lastSelectedTaskID")
        savedTags = d.stringArray(forKey: "savedTags") ?? []
        tagColors = d.dictionary(forKey: "tagColors") as? [String: String] ?? [:]
        hideInFullScreen = d.object(forKey: "hideInFullScreen") as? Bool ?? false
        tagGroups = (d.data(forKey: "tagGroups")).flatMap { try? JSONDecoder().decode([TagGroup].self, from: $0) } ?? []
    }

    // MARK: Tags

    /// "#Work Stuff" -> "work-stuff". Nil if nothing usable is left.
    nonisolated static func normalizeTag(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasPrefix("#") { s.removeFirst() }
        s = s.replacingOccurrences(of: " ", with: "-")
        s = String(s.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        return s.isEmpty ? nil : s
    }

    /// Every tag the app knows: saved in Settings, in a group, or used in a note.
    func allTags(in tasks: [NoteTask]) -> [String] {
        var set = Set(savedTags)
        for g in tagGroups { set.formUnion(g.tags) }
        for t in tasks { set.formUnion(ChipToken.values(of: .tag, in: t.body)) }
        return set.sorted()
    }

    func group(of tag: String) -> TagGroup? { tagGroups.first { $0.tags.contains(tag) } }

    func addTag(_ raw: String, group: UUID?) {
        guard let t = Self.normalizeTag(raw) else { return }
        moveTag(t, to: group)
    }

    /// Put a tag in a group (nil = no group). A tag is in at most one group.
    func moveTag(_ tag: String, to group: UUID?) {
        var groups = tagGroups
        for i in groups.indices { groups[i].tags.removeAll { $0 == tag } }
        var saved = savedTags.filter { $0 != tag }
        if let group, let i = groups.firstIndex(where: { $0.id == group }) {
            groups[i].tags.append(tag)
            groups[i].tags.sort()
        } else {
            saved.append(tag)
            saved.sort()
        }
        tagGroups = groups
        savedTags = saved
    }

    func forgetTag(_ tag: String) {
        savedTags.removeAll { $0 == tag }
        tagColors[tag] = nil
        var groups = tagGroups
        for i in groups.indices { groups[i].tags.removeAll { $0 == tag } }
        tagGroups = groups
    }

    func addGroup(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        tagGroups.append(TagGroup(name: n, tags: []))
    }

    func renameGroup(_ id: UUID, _ name: String) {
        guard let i = tagGroups.firstIndex(where: { $0.id == id }) else { return }
        tagGroups[i].name = name
    }

    /// Delete a group; its tags are kept, without a group.
    func deleteGroup(_ id: UUID) {
        guard let g = tagGroups.first(where: { $0.id == id }) else { return }
        tagGroups.removeAll { $0.id == id }
        savedTags = Array(Set(savedTags + g.tags)).sorted()
    }

    /// Read straight from UserDefaults so chip drawing (not tied to the main actor) can use it.
    nonisolated static func storedTagColor(_ tag: String) -> NSColor? {
        guard let hex = (UserDefaults.standard.dictionary(forKey: "tagColors") as? [String: String])?[tag] else { return nil }
        return NSColor(hex: hex)
    }

    var textColor: Color { Color(nsColor: NSColor(hex: textColorHex)) }
    var nsTextColor: NSColor { NSColor(hex: textColorHex) }

    func resetPanelSize() {
        panelWidth = 440
        panelHeight = 320
    }

    var externalStyle: ExternalStyle { ExternalStyle(rawValue: externalStyleRaw) ?? .glass }

    // MARK: Launch at login

    var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        objectWillChange.send()
    }
}

extension NSColor {
    convenience init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255.0,
                  green: CGFloat((v >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(v & 0xFF) / 255.0,
                  alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

extension Notification.Name {
    /// Chip colors or labels changed: editors redraw their chips.
    static let chipStyleChanged = Notification.Name("NotchNoteChipStyleChanged")
}
