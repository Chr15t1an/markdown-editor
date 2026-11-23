import AppKit

/// Test hook for launch probes, inert unless the defaults key `ProbeLogPath` is set
/// (`defaults write <domain> ProbeLogPath <file>`, or the launch argument `-ProbeLogPath <file>`).
///
/// When enabled the app writes its visible state as JSON to that file after each change, and
/// executes commands appended to `<file>.cmd` (one per line), polled every 0.2 s. The app creates
/// both files itself so they carry its own access grant under ~/Documents (TCC); append to the
/// command file in place (`>>`), never replace it. Commands go to the probe's target window
/// (the newest, until `window <n>` picks one):
///   type <text>          insert text at the caret (as typed)
///   key return|tab|backtab
///   select <loc> <len>   set the selection
///   action <selector>    send an action to the first responder (e.g. toggleBold:), else to the
///                        window's controller (newDocument:, toggleDefaultFolder:), else to NSApp's
///                        chain (app delegate actions such as newWindow:)
///   row <name>           click the sidebar row with that name
///   open <path>          open a folder or file
///   snapshot <png>       render the window content to a PNG
///   button <title>       press that button on the sheet in front (update alerts)
///   dump                 rewrite the state file
///   dump <path>          write the state at this point of the batch to <path>
///   window <n>           make the n-th window (1-based, creation order) the target
///   quit                 ignore the rest of the batch, rewrite the state, then NSApp.terminate
/// The state carries the target window's fields at top level, plus `windows` (every window's
/// state, creation order), `windowCount` (visible main windows), `target` (1-based index, 0 = none),
/// `defaultFolder`, `pid`, and `alert`: the title of the update sheet on screen ("" when none).
@MainActor
final class ProbeLog {
    static let shared = ProbeLog()
    weak var window: MainWindowController?
    /// Every main window in creation order (the app delegate points this at its registry).
    var allWindows: () -> [MainWindowController] = { [] }
    private let path: String?
    private var timer: Timer?
    /// Title of the update-check sheet currently shown (UpdateAlerts), so probes can assert on it:
    /// sheets are separate windows and do not appear in `snapshot`.
    private(set) var alert = ""

    init(path: String? = UserDefaults.standard.string(forKey: "ProbeLogPath")) {
        self.path = path
    }

    var isEnabled: Bool { path != nil }

    func start() {
        guard let path, timer == nil else { return }
        FileManager.default.createFile(atPath: path + ".cmd", contents: Data())
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func state() -> [String: Any] {
        let windows = allWindows()
        var state = window?.probeState() ?? [:]
        state["alert"] = alert
        state["windows"] = windows.map { $0.probeState() }
        state["windowCount"] = NSApp.windows.filter { $0.isVisible && $0.windowController is MainWindowController }.count
        state["target"] = window.flatMap { w in windows.firstIndex { $0 === w } }.map { $0 + 1 } ?? 0
        state["defaultFolder"] = UserDefaults.standard.string(forKey: DefaultFolder.key) ?? ""
        state["pid"] = Int(ProcessInfo.processInfo.processIdentifier)
        return state
    }

    func dump() {
        guard let path else { return }
        write(to: path)
    }

    private func write(to path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: state(), options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    func alertShown(_ title: String) {
        alert = title
        dump()
    }

    private func poll() {
        guard let path else { return }
        let cmdPath = path + ".cmd"
        guard let handle = FileHandle(forUpdatingAtPath: cmdPath) else { return }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd(), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return }
        try? handle.truncate(atOffset: 0)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if run(String(line)) == .quit {
                dump()
                NSApp.terminate(nil)   // runs applicationShouldTerminate synchronously
                return
            }
        }
        dump()
    }

    enum Outcome { case next, quit }

    /// Runs one command line; the probe's own commands are handled here, the rest by the target window.
    @discardableResult
    func run(_ line: String) -> Outcome {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "quit":
            return .quit
        case "window":
            let windows = allWindows()
            if let n = Int(arg), windows.indices.contains(n - 1) { window = windows[n - 1] }
        case "dump" where !arg.isEmpty:
            write(to: arg)
        default:
            window?.runProbeCommand(line)
        }
        return .next
    }
}
