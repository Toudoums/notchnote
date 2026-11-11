import AppKit
import Combine
import SwiftUI

/// Single source of truth for tasks and cards.
///
/// Persistence: one JSON file per task (`<uuid>.json`), written atomically
/// (`Data.write(options: .atomic)` = write temp file + rename), debounced 0.5 s after edits and
/// flushed on collapse / resign / quit. Deleting moves the file to the Trash, never unlinks it.
/// Tasks live either in Application Support (local) or in `<sync folder>/NotchNote/` (sync).
@MainActor
final class TaskStore: ObservableObject {
    static let shared = TaskStore()

    @Published private(set) var tasks: [NoteTask] = []
    @Published private(set) var cards: [Card] = []
    @Published var selectedID: UUID? {
        didSet { AppSettings.shared.lastSelectedTaskID = selectedID?.uuidString }
    }
    @Published var lastError: String?

    private let settings = AppSettings.shared
    private let io = DispatchQueue(label: "notchnote.io", qos: .utility)
    private var dirty = Set<UUID>()
    private var saveWork: DispatchWorkItem?
    private var syncWatcher: DispatchSourceFileSystemObject?
    private var syncReloadWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var loaded = false

    private init() {}

    // MARK: Locations

    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchNote", isDirectory: true)
    }
    var localDir: URL { Self.appSupport.appendingPathComponent("Tasks", isDirectory: true) }
    private var cardsURL: URL { Self.appSupport.appendingPathComponent("cards.json") }
    private var indexURL: URL { Self.appSupport.appendingPathComponent("index.json") }

    var syncDir: URL? {
        guard let p = settings.syncFolderPath, !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true).appendingPathComponent("NotchNote", isDirectory: true)
    }

    func directory(for location: StorageLocation) -> URL? {
        location == .local ? localDir : syncDir
    }

    private func fileURL(for task: NoteTask) -> URL? {
        directory(for: task.location)?.appendingPathComponent("\(task.id.uuidString).json")
    }

    // MARK: Coding

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Loading

    func loadAll() {
        guard !loaded else { return }
        loaded = true
        try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)

        var all = readDirectory(localDir, location: .local)
        if let s = syncDir { all += readDirectory(s, location: .sync) }

        // If the same id exists in both places keep the newest.
        var byID: [UUID: NoteTask] = [:]
        for t in all {
            if let existing = byID[t.id], existing.updatedAt >= t.updatedAt { continue }
            byID[t.id] = t
        }
        var ordered: [NoteTask] = []
        for id in readOrder() { if let t = byID.removeValue(forKey: id) { ordered.append(t) } }
        ordered += byID.values.sorted { $0.createdAt > $1.createdAt }
        tasks = ordered

        if tasks.isEmpty {
            var t = NoteTask(title: "Welcome")
            t.body = "# Welcome to NotchNote\n- [ ] Hover the notch to open this panel\n- [ ] Type \"- \" for a bullet, \"- [ ] \" for a checkbox\n- [ ] Press \u{2318}\u{21E7}S to favorite this task\n- [x] Install NotchNote"
            tasks = [t]
            dirty.insert(t.id)
            flush()
        }

        cards = readCards()
        if let s = settings.lastSelectedTaskID, let id = UUID(uuidString: s), tasks.contains(where: { $0.id == id }) {
            selectedID = id
        } else {
            selectedID = tasks.first?.id
        }

        startWatchingSync()
        settings.$syncFolderPath.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncFolderChanged() } }
        }.store(in: &cancellables)

        SpotlightIndexer.shared.index(tasks)
    }

    private func readDirectory(_ dir: URL, location: StorageLocation) -> [NoteTask] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [NoteTask] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), var t = try? Self.decoder.decode(NoteTask.self, from: data) else { continue }
            t.location = location
            out.append(t)
        }
        return out
    }

    private func readOrder() -> [UUID] {
        guard let data = try? Data(contentsOf: indexURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["order"] as? [String] else { return [] }
        return arr.compactMap(UUID.init(uuidString:))
    }

    private func writeOrder() {
        let obj: [String: Any] = ["order": tasks.map { $0.id.uuidString }]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return }
        let url = indexURL
        io.async { Self.writeAtomically(data, to: url) }
    }

    private func readCards() -> [Card] {
        guard let data = try? Data(contentsOf: cardsURL), let c = try? Self.decoder.decode([Card].self, from: data) else { return [] }
        return c
    }

    private func writeCards() {
        guard let data = try? Self.encoder.encode(cards) else { return }
        let url = cardsURL
        io.async { Self.writeAtomically(data, to: url) }
    }

    nonisolated private static func writeAtomically(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("NotchNote: write failed for %@: %@", url.path, error.localizedDescription)
        }
    }

    // MARK: Queries

    func task(_ id: UUID?) -> NoteTask? {
        guard let id else { return nil }
        return tasks.first { $0.id == id }
    }

    var selectedTask: NoteTask? { task(selectedID) }

    var favorites: [NoteTask] {
        tasks.filter { $0.isFavorite }.sorted { $0.favoriteOrder < $1.favoriteOrder }
    }

    // MARK: Mutations

    func update(_ id: UUID, _ mutate: (inout NoteTask) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let before = tasks[i]
        var t = before
        mutate(&t)
        guard t != before else { return }
        t.updatedAt = Date()
        tasks[i] = t
        markDirty(id)
    }

    func setBody(_ id: UUID, _ body: String) { update(id) { $0.body = body } }

    /// Number of notes that use a tag chip.
    func notesUsing(tag: String) -> Int { tasks.filter { $0.body.contains("[[tag:\(tag)]]") }.count }

    /// Remove a tag chip from every note.
    func removeTagEverywhere(_ tag: String) {
        let token = "[[tag:\(tag)]]"
        for t in tasks where t.body.contains(token) {
            update(t.id) { $0.body = $0.body.replacingOccurrences(of: token + " ", with: "").replacingOccurrences(of: token, with: "") }
        }
    }
    func setTitle(_ id: UUID, _ title: String) { update(id) { $0.title = title } }

    @discardableResult
    func createTask(title: String = "New task", body: String = "", select: Bool = true) -> NoteTask {
        var t = NoteTask(title: title)
        t.body = body
        tasks.insert(t, at: 0)
        if select { selectedID = t.id }
        markDirty(t.id)
        writeOrder()
        return t
    }

    func deleteTask(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let t = tasks[i]
        flush()
        if let url = fileURL(for: t) {
            io.async { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        }
        tasks.remove(at: i)
        dirty.remove(id)
        SpotlightIndexer.shared.remove([id])
        if selectedID == id { selectedID = tasks.indices.contains(i) ? tasks[i].id : tasks.last?.id }
        if tasks.isEmpty { createTask(title: "New task") }
        writeOrder()
    }

    /// Puts a deleted task back (used by Undo).
    func restoreTask(_ t: NoteTask, at index: Int) {
        guard !tasks.contains(where: { $0.id == t.id }) else { return }
        tasks.insert(t, at: min(max(index, 0), tasks.count))
        selectedID = t.id
        markDirty(t.id)
        writeOrder()
    }

    func index(of id: UUID) -> Int { tasks.firstIndex(where: { $0.id == id }) ?? 0 }

    @discardableResult
    func duplicate(_ id: UUID) -> NoteTask? {
        guard let src = task(id) else { return nil }
        let copy = createTask(title: src.title + " copy", body: src.body, select: true)
        update(copy.id) { $0.folder = src.folder }
        return copy
    }

    /// Removes finished items from one note; returns how many were removed (the old body is kept by the caller for Undo).
    func clearDone(_ id: UUID) -> Int {
        guard let t = task(id) else { return 0 }
        var removed = 0
        let kept = t.body.components(separatedBy: "\n").filter { line in
            let r = line.drop(while: { $0 == " " || $0 == "\t" })
            let done = r.hasPrefix("- [x]") || r.hasPrefix("- [X]")
            if done { removed += 1 }
            return !done
        }
        if removed > 0 { setBody(id, kept.joined(separator: "\n")) }
        return removed
    }

    func setFolder(_ id: UUID, _ folder: String) { update(id) { $0.folder = folder } }

    func toggleFavorite(_ id: UUID) {
        let nextOrder = (tasks.filter { $0.isFavorite }.map { $0.favoriteOrder }.max() ?? -1) + 1
        update(id) {
            $0.isFavorite.toggle()
            if $0.isFavorite { $0.favoriteOrder = nextOrder }
        }
    }

    func moveTasks(fromOffsets: IndexSet, toOffset: Int) {
        tasks.move(fromOffsets: fromOffsets, toOffset: toOffset)
        writeOrder()
    }

    func moveFavorites(fromOffsets: IndexSet, toOffset: Int) {
        var favs = favorites
        favs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for (order, f) in favs.enumerated() { update(f.id) { $0.favoriteOrder = order } }
    }

    // MARK: Cards

    func addCard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cards.insert(Card(text: trimmed), at: 0)
        writeCards()
    }

    func deleteCard(_ id: UUID) {
        cards.removeAll { $0.id == id }
        writeCards()
    }

    func copyCard(_ card: Card) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(card.text, forType: .string)
    }

    // MARK: Saving

    private func markDirty(_ id: UUID) {
        dirty.insert(id)
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flush() } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    /// Writes all dirty tasks to disk (asynchronously, atomically).
    func flush() {
        saveWork?.cancel()
        saveWork = nil
        guard !dirty.isEmpty else { return }
        var changed: [NoteTask] = []
        for id in dirty {
            guard let t = task(id), let url = fileURL(for: t), let data = try? Self.encoder.encode(t) else { continue }
            io.async { Self.writeAtomically(data, to: url) }
            changed.append(t)
        }
        dirty.removeAll()
        SpotlightIndexer.shared.indexSoon(changed)
        ReminderService.shared.syncChipReminders(tasks)
    }

    /// Used on quit: flush and wait until the IO queue is drained.
    func flushAndWait() {
        flush()
        writeCards()
        io.sync {}
    }

    // MARK: Moving between local storage and the sync folder

    func move(_ id: UUID, to location: StorageLocation) {
        guard let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].location != location else { return }
        guard let newDir = directory(for: location) else {
            lastError = "Choose a sync folder in Settings first."
            return
        }
        let old = tasks[i]
        var moved = old
        moved.location = location
        guard let oldURL = fileURL(for: old),
              let data = try? Self.encoder.encode(moved) else { return }
        let newURL = newDir.appendingPathComponent("\(id.uuidString).json")
        do {
            try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
            try data.write(to: newURL, options: .atomic)     // write the copy first ...
        } catch {
            lastError = "Could not move task: \(error.localizedDescription)"
            return
        }
        tasks[i] = moved
        dirty.remove(id)
        io.async { try? FileManager.default.trashItem(at: oldURL, resultingItemURL: nil) }   // ... then trash the original
    }

    // MARK: Sync folder watching

    private func syncFolderChanged() {
        tasks.removeAll { $0.location == .sync && !dirty.contains($0.id) }
        reloadSync()
        startWatchingSync()
    }

    private func startWatchingSync() {
        syncWatcher?.cancel()
        syncWatcher = nil
        guard let dir = syncDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleSyncReload() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        syncWatcher = src
    }

    private func scheduleSyncReload() {
        syncReloadWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reloadSync() } }
        syncReloadWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    /// Merge files from the sync folder (written by another Mac) into memory. Newest `updatedAt` wins.
    func reloadSync() {
        guard let dir = syncDir else { return }
        let onDisk = readDirectory(dir, location: .sync)
        var seen = Set<UUID>()
        var result = tasks
        for t in onDisk {
            seen.insert(t.id)
            if let i = result.firstIndex(where: { $0.id == t.id }) {
                if t.updatedAt > result[i].updatedAt, !dirty.contains(t.id) { result[i] = t }
            } else {
                result.append(t)
            }
        }
        result.removeAll { $0.location == .sync && !seen.contains($0.id) && !dirty.contains($0.id) }
        if result != tasks {
            tasks = result
            if result.isEmpty { createTask(title: "New task") }
            if let s = selectedID, !tasks.contains(where: { $0.id == s }) { selectedID = tasks.first?.id }
            SpotlightIndexer.shared.index(tasks)
        }
    }
}
