import AppKit

/// Test hook for launch probes, inert unless the defaults key `ProbeLogPath` is set
/// (`defaults write com.chri5tian.markdown-editor ProbeLogPath <file>`).
///
/// When enabled the app writes its visible state as JSON to that file after each change, and
/// executes commands appended to `<file>.cmd` (one per line), polled every 0.2 s. The app creates
/// both files itself so they carry its own access grant under ~/Documents (TCC); append to the
/// command file in place (`>>`), never replace it:
///   type <text>          insert text at the caret (as typed)
///   key return|tab|backtab
///   select <loc> <len>   set the selection
///   action <selector>    send an action to the first responder (e.g. toggleBold:), else to
///                        NSApp's chain (app delegate actions such as newDocument:)
///   row <name>           click the sidebar row with that name
///   open <path>          open a folder or file
///   snapshot <png>       render the window content to a PNG
///   dump                 rewrite the state file
/// The state also carries `alert`: the title of the update sheet on screen ("" when none).
@MainActor
final class ProbeLog {
    static let shared = ProbeLog()
    weak var window: MainWindowController?
    private let path: String? = UserDefaults.standard.string(forKey: "ProbeLogPath")
    private var timer: Timer?
    /// Title of the update-check sheet currently shown (UpdateAlerts), so probes can assert on it:
    /// sheets are separate windows and do not appear in `snapshot`.
    private(set) var alert = ""

    var isEnabled: Bool { path != nil }

    func start() {
        guard let path, timer == nil else { return }
        FileManager.default.createFile(atPath: path + ".cmd", contents: Data())
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { ProbeLog.shared.poll() }
        }
    }

    func dump() {
        guard let path, let window else { return }
        var state = window.probeState()
        state["alert"] = alert
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else { return }
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
            window?.runProbeCommand(String(line))
        }
        dump()
    }
}
