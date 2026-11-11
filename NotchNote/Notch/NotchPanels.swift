import AppKit
import SwiftUI

private let notchWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

/// The expanded panel. Borderless, non-activating (hovering does not steal focus from the frontmost app),
/// but it can become key so typing works once you click into it.
final class NotchPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onToggleFavorite: (() -> Void)?

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = notchWindowLevel
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Keep the frame exactly where we put it, even over the menu bar / notch area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "s" {
                onToggleFavorite?()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Small always-present window over the notch / pill. It owns hover, click and text-drag detection.
final class HotZonePanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = notchWindowLevel
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class HotZoneView: NSView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var onDragEnter: (() -> Void)?
    var onDropText: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.string])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEnter?()
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let s = sender.draggingPasteboard.string(forType: .string) else { return false }
        onDropText?(s)
        return true
    }
}

/// Hosting view that lets mouse events fall through to its superview (the HotZoneView).
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Container for the expanded panel that reports the pointer leaving / entering.
final class PanelContainerView: NSView {
    var onExit: (() -> Void)?
    var onEnter: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

// MARK: Every desktop

/// "All Spaces" windows alone are not reliable for an accessory app: macOS can leave them behind on the
/// desktop where they were created. Like other notch apps, we also put the notch windows in a window-server
/// space that is shown on top of every desktop and full-screen app. Private API (SkyLight), loaded at
/// runtime; if it is missing the app keeps working with the normal behaviour.
@MainActor
final class NotchSpace {
    static let shared = NotchSpace()

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceSetLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Void
    private typealias AddWindows = @convention(c) (Int32, CFArray, CFArray) -> Void

    private var connection: Int32 = 0
    private var space: UInt64 = 0
    private var addWindows: AddWindows?

    private init() {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return }
        func load<T>(_ name: String, _: T.Type) -> T? {
            guard let p = dlsym(lib, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let main = load("CGSMainConnectionID", MainConnection.self),
              let create = load("CGSSpaceCreate", SpaceCreate.self),
              let setLevel = load("CGSSpaceSetAbsoluteLevel", SpaceSetLevel.self),
              let show = load("CGSShowSpaces", ShowSpaces.self),
              let add = load("CGSAddWindowsToSpaces", AddWindows.self) else { return }
        connection = main()
        space = create(connection, 1, nil)
        guard space != 0 else { return }
        setLevel(connection, space, Int32.max)
        show(connection, [NSNumber(value: space)] as CFArray)
        addWindows = add
    }

    /// Safe to call repeatedly (after every order-front).
    func adopt(_ window: NSWindow) {
        guard let addWindows, window.windowNumber > 0 else { return }
        addWindows(connection, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: space)] as CFArray)
    }
}
