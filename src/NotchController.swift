import AppKit
import SwiftUI
import Combine

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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.userInfo?["brim"] != nil }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["brim": true]))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); NSCursor.arrow.set() }
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
            if self?.model.open == true, !(self?.inside(open: true) ?? false) { self?.collapse() }
        }) { monitors.append(m) }
    }

    private(set) var current: NSScreen?

    static func id(_ s: NSScreen) -> String { s.localizedName }

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
            model.hasNotch = true
            model.notchWidth = r.minX - l.maxX
            model.notchHeight = s.safeAreaInsets.top
            model.topInset = 0
        } else {
            let bar = max(22, f.maxY - s.visibleFrame.maxY)
            model.hasNotch = false
            model.notchWidth = 14
            model.topInset = 4
            model.notchHeight = bar - 8
        }
        let c = Self.canvas
        var mid = f.midX
        if model.hasNotch, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            let lx = l.minX >= f.minX - 1 && r.maxX <= f.maxX + 1 ? l.maxX : f.minX + l.maxX
            let rx = l.minX >= f.minX - 1 && r.maxX <= f.maxX + 1 ? r.minX : f.minX + r.minX
            mid = (lx + rx) / 2
        }
        panel.setFrame(NSRect(x: mid - c.width / 2, y: f.maxY - c.height, width: c.width, height: c.height), display: true)
    }

    private func shapeRect(open: Bool) -> NSRect {
        guard current != nil else { return .zero }
        let size = open ? model.openSize(rows: store.visible.count, footer: store.announcement != nil) : model.collapsedSize
        let inset = model.hasNotch ? NotchModel.topRadius : 0
        let w = size.width - 2 * inset
        let pf = panel.frame
        return NSRect(x: pf.midX - w / 2, y: pf.maxY - model.topInset - size.height, width: w, height: size.height)
    }

    private func inside(open: Bool) -> Bool {
        let p = NSEvent.mouseLocation
        return shapeRect(open: open).insetBy(dx: open ? -6 : 0, dy: open ? -8 : 0).contains(p)
    }

    private func track() {
        if !model.open, store.settings.display == "auto", let cur = current,
           !NSMouseInRect(NSEvent.mouseLocation, cur.frame, false) {
            place()
        }
        if model.open {
            if inside(open: true) {
                closeTimer?.invalidate(); closeTimer = nil
                NSCursor.arrow.set()
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
