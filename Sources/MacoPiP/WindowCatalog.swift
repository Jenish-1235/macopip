import AppKit

struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let bounds: CGRect
    let isOnScreen: Bool

    var label: String {
        let text = title.isEmpty ? appName : "\(appName) — \(title)"
        return text.count > 70 ? String(text.prefix(69)) + "…" : text
    }
}

enum WindowCatalog {
    /// Normal app windows across all Spaces, front-to-back, excluding our own.
    static func list() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        let windows: [WindowInfo] = raw.compactMap { dict in
            guard (dict[kCGWindowLayer as String] as? Int) == 0,
                  let id = dict[kCGWindowNumber as String] as? CGWindowID,
                  let pid = dict[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsDict = dict[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary),
                  bounds.width >= 120, bounds.height >= 80,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular
            else { return nil }

            let title = dict[kCGWindowName as String] as? String ?? ""
            let onScreen = dict[kCGWindowIsOnscreen as String] as? Bool ?? false
            // Untitled off-screen windows are almost always invisible helper windows.
            guard !title.isEmpty || onScreen else { return nil }

            let appName = app.localizedName ?? dict[kCGWindowOwnerName as String] as? String ?? "App"
            return WindowInfo(id: id, pid: pid, appName: appName, title: title, bounds: bounds, isOnScreen: onScreen)
        }

        // Stable partition: visible windows first, each group keeping z-order.
        return windows.filter(\.isOnScreen) + windows.filter { !$0.isOnScreen }
    }

    /// The front-most window of the currently active app.
    static func focusedWindow() -> WindowInfo? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        return list().first { $0.pid == front.processIdentifier }
    }

    static func info(for id: CGWindowID) -> (bounds: CGRect, title: String)? {
        guard let dict = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let boundsDict = dict[kCGWindowBounds as String],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary)
        else { return nil }
        return (bounds, dict[kCGWindowName as String] as? String ?? "")
    }
}
