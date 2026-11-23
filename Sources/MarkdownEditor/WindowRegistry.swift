import AppKit
import MarkdownCore

/// Every main window, and which one an app-level action or an external open goes to.
/// Rule: a note is open in at most one window (two FileSession presenters on one file
/// deadlock the main thread on a coordinated save — research Q4).
@MainActor
final class WindowRegistry {
    private(set) var controllers: [MainWindowController] = []   // creation order
    private weak var lastActive: MainWindowController?
    /// Shows a new window; replaced in tests (no on-screen windows in the headless runner).
    var show: @MainActor (MainWindowController) -> Void = { $0.showWindow(nil) }
    /// Brings a window forward; replaced in tests.
    var focus: @MainActor (MainWindowController) -> Void = { $0.window?.makeKeyAndOrderFront(nil) }

    /// Key window's controller, else main, else the most recently active, else the newest.
    var target: MainWindowController? {
        for window in [NSApp.keyWindow, NSApp.mainWindow] {
            if let c = window?.windowController as? MainWindowController, controllers.contains(where: { $0 === c }) {
                return c
            }
        }
        if let lastActive, controllers.contains(where: { $0 === lastActive }) { return lastActive }
        return controllers.last
    }

    /// Creates a window, wires it to the registry and shows it.
    @discardableResult
    func makeWindow() -> MainWindowController {
        let c = MainWindowController()
        add(c)
        return c
    }

    /// Wires an existing controller into the registry and shows it (tests build their own).
    func add(_ c: MainWindowController) {
        c.registry = self
        c.onClose = { [weak self] in self?.remove($0) }
        c.onBecomeKey = { [weak self] in self?.didBecomeKey($0) }
        controllers.append(c)
        lastActive = c
        show(c)
    }

    func remove(_ c: MainWindowController) {
        controllers.removeAll { $0 === c }
    }

    func didBecomeKey(_ c: MainWindowController) { lastActive = c }

    /// The window (other than `except`) whose open note is `url`.
    func holder(of url: URL, except: MainWindowController? = nil) -> MainWindowController? {
        controllers.first { c in
            c !== except && (c.session.currentURL.map { Self.sameFile($0, url) } ?? false)
        }
    }

    /// True when `a` and `b` are one file: same file identity when both exist (catches case variants,
    /// symlinks and hard links), else the same standardized, symlink-resolved path, case-folded.
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        if let ia = (try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject,
           let ib = (try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject {
            return ia.isEqual(ib)
        }
        func key(_ u: URL) -> String { u.standardizedFileURL.resolvingSymlinksInPath().path.lowercased() }
        return key(a) == key(b)
    }

    /// External / Open… routing. (a) a note open in some window → that window comes forward;
    /// (b) a folder that is some window's root, or a file inside some window's root → that window;
    /// (c) otherwise `from`, else the target window (re-rooting as one window always did).
    func open(_ url: URL, from: MainWindowController? = nil) {
        guard let resolved = OpenTarget.resolve(url) else { return }
        if let file = resolved.file, !ImageFile.isImage(file), let holder = holder(of: file) {
            focus(holder)
            return
        }
        var order: [MainWindowController] = []
        for c in [from, target].compactMap({ $0 }) + controllers where !order.contains(where: { $0 === c }) {
            order.append(c)
        }
        let owner = order.first { c in
            guard let root = c.folder else { return false }
            if let file = resolved.file { return MainWindowController.isInside(file.deletingLastPathComponent(), root) }
            return MainWindowController.isInside(resolved.folder, root) && MainWindowController.isInside(root, resolved.folder)
        }
        let window = owner ?? from ?? target ?? makeWindow()
        window.open(url)
        focus(window)
    }

    func saveAll() {
        for c in controllers { c.save() }
    }

    /// Front to back (target first, then the rest in creation order); stops at the first refusal.
    func prepareAllToClose() -> Bool {
        var order = controllers
        if let t = target, let i = order.firstIndex(where: { $0 === t }) {
            order.remove(at: i)
            order.insert(t, at: 0)
        }
        for c in order {
            guard c.prepareToClose() else { return false }
        }
        return true
    }
}
