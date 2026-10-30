import AppKit
import SwiftUI
import Combine

/// A borderless panel above the menu bar, centred on the notch. It ignores the mouse except
/// where the black shape actually is, so the menu bar keeps working around it.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchController {
    let store: Store
    let model = NotchModel()
    let panel = NotchPanel()
    private var monitors: [Any] = []
    private var bag: Set<AnyCancellable> = []
    private var openTimer: Timer?
    private var closeTimer: Timer?
    var onSettings: () -> Void = {}
    var onAdd: (Provider) -> Void = { _ in }

    static let canvas = CGSize(width: 640, height: 480)

    init(store: Store) {
        self.store = store
    }

    func show() {
        let root = NotchView(store: store, model: model, onSettings: { [weak self] in self?.settings() },
                             onAdd: { [weak self] p in self?.collapse(); self?.onAdd(p) })
        let host = FirstMouseHost(rootView: root)
        host.frame = NSRect(origin: .zero, size: Self.canvas)
        panel.contentView = host
        place()
        panel.orderFrontRegardless()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.place() }.store(in: &bag)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.panel.orderFrontRegardless() }.store(in: &bag)

        let handler: (NSEvent) -> Void = { [weak self] _ in self?.track() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { handler($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            // A click elsewhere closes it at once.
            if self?.model.open == true, !(self?.inside(open: true) ?? false) { self?.collapse() }
        }) { monitors.append(m) }
    }

    /// The screen it sits on now.
    private(set) var current: NSScreen?

    static func id(_ s: NSScreen) -> String { s.localizedName }

    /// "auto" follows the pointer from screen to screen; otherwise the named screen if it's connected.
    func screen() -> NSScreen? {
        let pref = store.settings.display
        if pref != "auto", let s = NSScreen.screens.first(where: { Self.id($0) == pref }) { return s }
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    func place() {
        guard let s = screen() else { return }
        current = s
        let f = s.frame
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            // Hug the camera housing: same height, centred on the gap between the two menu-bar halves.
            model.hasNotch = true
            model.notchWidth = r.minX - l.maxX
            model.notchHeight = s.safeAreaInsets.top
            model.topInset = 0
        } else {
            // No notch: a small pill floating in the menu bar instead of a fake notch.
            let bar = max(22, f.maxY - s.visibleFrame.maxY)
            model.hasNotch = false
            model.notchWidth = 14
            model.topInset = 4
            model.notchHeight = bar - 8
        }
        let c = Self.canvas
        // Centre on the notch itself (it can sit off-centre in the frame on some scaled modes).
        var mid = f.midX
        if model.hasNotch, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            // The areas may come in screen-local or global coordinates; normalise to global.
            let lx = l.minX >= f.minX - 1 && r.maxX <= f.maxX + 1 ? l.maxX : f.minX + l.maxX
            let rx = l.minX >= f.minX - 1 && r.maxX <= f.maxX + 1 ? r.minX : f.minX + r.minX
            mid = (lx + rx) / 2
        }
        panel.setFrame(NSRect(x: mid - c.width / 2, y: f.maxY - c.height, width: c.width, height: c.height), display: true)
    }

    /// The black shape's current rect in screen coordinates.
    private func shapeRect(open: Bool) -> NSRect {
        guard current != nil else { return .zero }
        let size = open ? model.openSize(rows: store.visible.count, footer: store.announcement != nil, logins: store.loginTools.count) : model.collapsedSize
        let inset = model.hasNotch ? NotchModel.topRadius : 0
        let w = size.width - 2 * inset
        let pf = panel.frame
        return NSRect(x: pf.midX - w / 2, y: pf.maxY - model.topInset - size.height, width: w, height: size.height)
    }

    private func inside(open: Bool) -> Bool {
        let p = NSEvent.mouseLocation
        // A little slack below so a fast flick into the panel doesn't close it.
        return shapeRect(open: open).insetBy(dx: open ? -6 : 0, dy: open ? -8 : 0).contains(p)
    }

    private func track() {
        // Follow the pointer to another screen (only while closed, so it never jumps mid-use).
        if !model.open, store.settings.display == "auto", let cur = current,
           !NSMouseInRect(NSEvent.mouseLocation, cur.frame, false) {
            place()
        }
        if model.open {
            if inside(open: true) {
                closeTimer?.invalidate(); closeTimer = nil
            } else if closeTimer == nil {
                closeTimer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.collapse() }
                }
            }
        } else if inside(open: false) {
            panel.ignoresMouseEvents = false
            if openTimer == nil {
                openTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.openTimer = nil
                        if self.inside(open: false) { self.expand() }
                    }
                }
            }
        } else {
            openTimer?.invalidate(); openTimer = nil
            panel.ignoresMouseEvents = true
        }
    }

    func expand() {
        guard !model.open else { return }
        panel.ignoresMouseEvents = false
        model.open = true
        Task { await store.refresh(force: false) }
    }

    func collapse() {
        closeTimer?.invalidate(); closeTimer = nil
        guard model.open else { return }
        model.open = false
        panel.ignoresMouseEvents = true
    }

    private func settings() {
        collapse()
        onSettings()
    }
}
