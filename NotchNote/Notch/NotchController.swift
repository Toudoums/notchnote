import AppKit
import Combine
import SwiftUI

enum PanelTab: String { case notes, cards, today }

/// Per-display UI state shared between the AppKit windows and the SwiftUI views.
@MainActor
final class PanelState: ObservableObject {
    @Published var isOpen = false
    @Published var pinned = false
    @Published var tab: PanelTab = .notes
    let geometry: NotchGeometry
    init(geometry: NotchGeometry) { self.geometry = geometry }
}

@MainActor
final class NotchController: NSObject {
    static let shared = NotchController()

    private struct Slot {
        let geometry: NotchGeometry
        let state: PanelState
        let hot: HotZonePanel
        let main: NotchPanel
        let container: PanelContainerView
    }

    private var slots: [CGDirectDisplayID: Slot] = [:]
    private var expandedID: CGDirectDisplayID?
    private var collapseWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var rebuildWork: DispatchWorkItem?
    private var relayoutPending = false
    private var clickMonitor: Any?
    private var fullScreenTimer: Timer?
    /// Displays where the notch is hidden because an app is full screen there.
    private var hiddenForFullScreen = Set<CGDirectDisplayID>()
    private var cancellables = Set<AnyCancellable>()
    private let settings = AppSettings.shared

    // MARK: Lifecycle

    func start() {
        rebuild()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Mission Control desktops: keep the notch on every Space and re-assert it after each switch.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        // Click anywhere outside the expanded panel collapses it (unless pinned).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleOutsideClick() }
        }

        // Optional: hide the notch while an app or a web page is full screen on that display.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(fullScreenMaybeChanged),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        fullScreenTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFullScreenHiding() }
        }
        settings.$hideInFullScreen.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateFullScreenHiding() } }
        }.store(in: &cancellables)

        // A different style for displays without a notch needs the panels rebuilt.
        settings.$externalStyleRaw.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.rebuild() } }
        }.store(in: &cancellables)

        // Re-layout when size / notch settings change (debounced to the next run-loop turn).
        settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.relayoutSoon() } }
        }.store(in: &cancellables)
    }

    @objc private func fullScreenMaybeChanged() {
        // Let the full-screen animation finish before looking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated { self?.updateFullScreenHiding() }
        }
    }

    private func updateFullScreenHiding() {
        let covered = settings.hideInFullScreen ? Self.fullScreenDisplays() : []
        for (id, slot) in slots {
            if covered.contains(id) {
                guard !hiddenForFullScreen.contains(id) else { continue }
                hiddenForFullScreen.insert(id)
                collapse(id, force: true, animated: false)
                slot.hot.orderOut(nil)
            } else if hiddenForFullScreen.remove(id) != nil {
                slot.hot.orderFrontRegardless()
                NotchSpace.shared.adopt(slot.hot)
            }
        }
    }

    /// Displays covered by another app's full-screen window (a window exactly the size of the display).
    private static func fullScreenDisplays() -> Set<CGDirectDisplayID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var out = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            let id = screen.displayID
            let b = CGDisplayBounds(id)
            for w in list {
                guard (w[kCGWindowLayer as String] as? Int) == 0,
                      (w[kCGWindowOwnerPID as String] as? Int32) != me,
                      let dict = w[kCGWindowBounds as String] as? NSDictionary,
                      let r = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
                if abs(r.minX - b.minX) < 1, abs(r.minY - b.minY) < 1, r.width >= b.width - 1, r.height >= b.height - 1 {
                    out.insert(id)
                    break
                }
            }
        }
        return out
    }

    @objc private func spaceChanged() {
        updateFullScreenHiding()
        let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        for slot in slots.values where !hiddenForFullScreen.contains(slot.geometry.displayID) {
            slot.hot.collectionBehavior = behavior
            slot.main.collectionBehavior = behavior
            slot.hot.orderFrontRegardless()
            NotchSpace.shared.adopt(slot.hot)
            if slot.state.isOpen { slot.main.orderFrontRegardless(); NotchSpace.shared.adopt(slot.main) }
        }
    }

    @objc private func screensChanged() {
        // Displays appear/disappear in bursts (clamshell, wake, hot-plug). Wait for things to settle.
        rebuildWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.rebuildIfNeeded() } }
        rebuildWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    private func rebuildIfNeeded() {
        let wanted = NSScreen.screens.map { NotchGeometry(screen: $0) }
        let current = slots.values.map { $0.geometry }
        let same = wanted.count == current.count && wanted.allSatisfy { w in current.contains(w) }
        if !same { rebuild() }
    }

    private func rebuild() {
        collapseAll(animated: false)
        for slot in slots.values {
            slot.hot.orderOut(nil)
            slot.main.orderOut(nil)
            slot.hot.contentView = nil
            slot.main.contentView = nil
        }
        slots.removeAll()
        expandedID = nil
        hiddenForFullScreen.removeAll()

        for screen in NSScreen.screens {
            let geo = NotchGeometry(screen: screen)
            slots[geo.displayID] = makeSlot(geo)
        }
    }

    private func makeSlot(_ geo: NotchGeometry) -> Slot {
        let state = PanelState(geometry: geo)
        let id = geo.displayID

        // Hot zone (always visible, tiny)
        let hot = HotZonePanel(frame: geo.hotFrame(settings))
        let hotView = HotZoneView(frame: NSRect(origin: .zero, size: hot.frame.size))
        hotView.autoresizingMask = [.width, .height]
        let pill = PassthroughHostingView(rootView: CollapsedPillView(state: state))
        pill.sizingOptions = []
        pill.safeAreaRegions = []   // Xcode 26 SDK: don't add the notch as extra top inset
        pill.frame = hotView.bounds
        pill.autoresizingMask = [.width, .height]
        hotView.addSubview(pill)
        hotView.onHover = { [weak self] in self?.expand(id, focus: false, haptic: true) }
        hotView.onClick = { [weak self] in self?.expand(id, focus: true, haptic: false) }
        hotView.onDragEnter = { [weak self] in self?.expand(id, focus: false, haptic: true) }
        hotView.onDropText = { text in TaskStore.shared.addCard(text) }
        hot.contentView = hotView
        hot.orderFrontRegardless()
        NotchSpace.shared.adopt(hot)

        // Expanded panel (shown on demand)
        let main = NotchPanel(frame: geo.expandedFrame(settings))
        let container = PanelContainerView(frame: NSRect(origin: .zero, size: main.frame.size))
        container.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: NotchPanelView(state: state))
        host.sizingOptions = []
        host.safeAreaRegions = []   // Xcode 26 SDK: don't add the notch as extra top inset
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        container.onExit = { [weak self] in self?.scheduleCollapse(id) }
        container.onEnter = { [weak self] in self?.collapseWork?.cancel() }
        main.contentView = container
        main.onEscape = { [weak self] in self?.collapse(id, force: true) }
        main.onToggleFavorite = { if let sel = TaskStore.shared.selectedID { TaskStore.shared.toggleFavorite(sel) } }

        return Slot(geometry: geo, state: state, hot: hot, main: main, container: container)
    }

    private func relayoutSoon() {
        guard !relayoutPending else { return }
        relayoutPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.relayoutPending = false
                for slot in self.slots.values {
                    slot.hot.setFrame(slot.geometry.hotFrame(self.settings), display: true)
                    slot.main.setFrame(slot.geometry.expandedFrame(self.settings), display: true)
                }
            }
        }
    }

    // MARK: Expand / collapse

    func expand(_ id: CGDirectDisplayID, focus: Bool, haptic: Bool) {
        guard let slot = slots[id], !hiddenForFullScreen.contains(id) else { return }
        collapseWork?.cancel()
        hideWork?.cancel()

        if let other = expandedID, other != id { collapse(other, force: true) }
        let wasOpen = slot.state.isOpen
        expandedID = id

        if !slot.main.isVisible {
            slot.main.setFrame(slot.geometry.expandedFrame(settings), display: false)
            slot.main.orderFrontRegardless()
        }
        NotchSpace.shared.adopt(slot.main)
        if !wasOpen {
            if haptic { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            // One run-loop turn later so SwiftUI has rendered the closed state to animate from.
            DispatchQueue.main.async { MainActor.assumeIsolated { slot.state.isOpen = true } }
        }
        if focus { activate(id) }
    }

    /// Make the panel on this display key and put the caret in the editor. Esc / typing then go to this display only.
    func activate(_ id: CGDirectDisplayID) {
        guard let slot = slots[id] else { return }
        // The panel is non-activating and lives on every Space, so make it key *without* activating the app:
        // activating an accessory app can make macOS jump back to the desktop that holds its other windows.
        // Never activate the app here: that is what makes macOS jump to another desktop.
        slot.main.makeKeyAndOrderFront(nil)
        NotchSpace.shared.adopt(slot.main)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let editor = slot.main.contentView?.findEditor() { slot.main.makeFirstResponder(editor) }
            }
        }
    }

    private func scheduleCollapse(_ id: CGDirectDisplayID) {
        guard let slot = slots[id], slot.state.isOpen, !slot.state.pinned else { return }
        collapseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.collapse(id, force: false) } }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    func collapse(_ id: CGDirectDisplayID, force: Bool, animated: Bool = true) {
        guard let slot = slots[id] else { return }
        if !force, slot.state.pinned { return }
        // Pointer came back in the meantime (e.g. moved onto the window edge)? Stay open.
        if !force, NSMouseInRect(NSEvent.mouseLocation, slot.main.frame, false) { return }
        collapseWork?.cancel()
        TaskStore.shared.flush()
        slot.state.pinned = false
        slot.state.isOpen = false
        if expandedID == id { expandedID = nil }

        hideWork?.cancel()
        let hide = {
            guard !slot.state.isOpen else { return }
            slot.main.orderOut(nil)
        }
        if animated {
            let w = DispatchWorkItem { MainActor.assumeIsolated { hide() } }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: w)
        } else {
            hide()
        }
    }

    private func collapseAll(animated: Bool) {
        for id in Array(slots.keys) { collapse(id, force: true, animated: animated) }
    }

    private func handleOutsideClick() {
        guard let id = expandedID, let slot = slots[id] else { return }
        if !NSMouseInRect(NSEvent.mouseLocation, slot.main.frame, false) { collapse(id, force: true) }
    }

    /// The editor shown in this display's panel (used by the formatting bar).
    func editor(for id: CGDirectDisplayID) -> EditorTextView? {
        slots[id]?.main.contentView?.findEditor()
    }

    // MARK: Entry points used elsewhere

    /// Open the panel on the display under the mouse, pinned, with the editor focused.
    func showPinnedOnActiveScreen() {
        let id = NSScreen.underMouse()?.displayID ?? slots.keys.first
        guard let id, let slot = slots[id] else { return }
        slot.state.pinned = true
        expand(id, focus: true, haptic: false)
    }

    func openTask(_ taskID: UUID) {
        TaskStore.shared.selectedID = taskID
        showPinnedOnActiveScreen()
    }

    func toggleOnActiveScreen() {
        let id = NSScreen.underMouse()?.displayID ?? slots.keys.first
        guard let id, let slot = slots[id] else { return }
        if slot.state.isOpen { collapse(id, force: true) } else { showPinnedOnActiveScreen() }
    }
}
