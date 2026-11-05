import AppKit

/// Chromium stops rendering windows that macOS reports as hidden (on another Space or fully
/// covered). A pinned Chrome window would then freeze and ignore forwarded scrolls, so we
/// relaunch the browser with occlusion backgrounding turned off.
enum ChromiumSupport {
    static let flag = "--disable-backgrounding-occluded-windows"

    private static let bundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    static func needsRelaunch(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier, bundleIDs.contains(id) else { return false }
        return !arguments(of: app.processIdentifier).contains(flag)
    }

    /// Quits the browser like ⌘Q, then reopens it with the flag and the previous session.
    /// Calls back with the new process, or nil if it didn't quit (e.g. a "downloads in progress" prompt was cancelled).
    @MainActor
    static func relaunch(_ app: NSRunningApplication, completion: @escaping (NSRunningApplication?) -> Void) {
        guard let url = app.bundleURL else { completion(nil); return }
        app.terminate()

        let deadline = Date().addingTimeInterval(30)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            guard app.isTerminated || Date() > deadline else { return }
            timer.invalidate()
            guard app.isTerminated else { completion(nil); return }

            let config = NSWorkspace.OpenConfiguration()
            config.arguments = [flag, "--restore-last-session"]
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { newApp, error in
                if let error { NSLog("MacoPiP: relaunch failed: \(error.localizedDescription)") }
                DispatchQueue.main.async { completion(newApp) }
            }
        }
    }

    /// Command-line arguments of another process (same user), via KERN_PROCARGS2.
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }

        // Layout: argc, executable path, NUL padding, then argv[0..<argc] NUL-separated.
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }
}
