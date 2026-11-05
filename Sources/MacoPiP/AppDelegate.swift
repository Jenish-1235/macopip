import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var pips: [PiPController] = []
    private var allHidden = false
    private var pinAnywayPIDs: Set<pid_t> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pip", accessibilityDescription: "MacoPiP")
        statusMenu.delegate = self
        statusItem.menu = statusMenu

        let ctrlOpt = controlKey | optionKey
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_P, modifiers: ctrlOpt) { [weak self] in
            MainActor.assumeIsolated { self?.togglePinFocusedWindow() }
        }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_O, modifiers: ctrlOpt) { [weak self] in
            MainActor.assumeIsolated { self?.showPickerAtMouse() }
        }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_H, modifiers: ctrlOpt) { [weak self] in
            MainActor.assumeIsolated { self?.toggleAllHidden() }
        }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_J, modifiers: ctrlOpt) { [weak self] in
            MainActor.assumeIsolated { self?.pips.last?.jumpToSource() }
        }

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pips.forEach { $0.close() }
    }

    // MARK: - Actions

    private func togglePinFocusedWindow() {
        guard let window = WindowCatalog.focusedWindow() else { NSSound.beep(); return }
        togglePin(window)
    }

    private func togglePin(_ window: WindowInfo) {
        if let existing = pips.first(where: { $0.windowID == window.id }) {
            existing.close()
            return
        }
        Task { await pin(window) }
    }

    private func pin(_ info: WindowInfo) async {
        if let app = NSRunningApplication(processIdentifier: info.pid),
           !pinAnywayPIDs.contains(info.pid), ChromiumSupport.needsRelaunch(app) {
            switch askToRelaunch(app) {
            case .alertFirstButtonReturn:
                relaunchAndRepin(app, title: info.title)
                return
            case .alertSecondButtonReturn:
                pinAnywayPIDs.insert(info.pid)
            default:
                return
            }
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard let scWindow = content.windows.first(where: { $0.windowID == info.id }) else {
                NSSound.beep()
                return
            }
            let pip = PiPController(window: scWindow, appName: info.appName, stackIndex: pips.count)
            pip.onClose = { [weak self] closed in self?.pips.removeAll { $0 === closed } }
            pips.append(pip)
            try await pip.start()
            if allHidden { pip.setUserHidden(true) }
        } catch {
            NSLog("MacoPiP: pin failed: \(error.localizedDescription)")
            pips.removeAll { $0.windowID == info.id }
            showPermissionAlert()
        }
    }

    private func askToRelaunch(_ app: NSRunningApplication) -> NSApplication.ModalResponse {
        let name = app.localizedName ?? "the browser"
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Relaunch \(name) for PiP?"
        alert.informativeText = """
            \(name) pauses windows that are hidden behind other apps, so the PiP would freeze and \
            scrolling wouldn't show. MacoPiP can quit \(name) and reopen it with that pausing turned off. \
            Your windows and tabs are restored, and this window gets pinned again.
            """
        alert.addButton(withTitle: "Relaunch \(name)")
        alert.addButton(withTitle: "Pin Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal()
    }

    private func relaunchAndRepin(_ app: NSRunningApplication, title: String) {
        ChromiumSupport.relaunch(app) { [weak self] newApp in
            guard let self, let newApp else { NSSound.beep(); return }
            self.repinWhenReady(pid: newApp.processIdentifier, title: title, attemptsLeft: 40)
        }
    }

    /// Restored windows appear over a few seconds; wait for the one with the same title.
    private func repinWhenReady(pid: pid_t, title: String, attemptsLeft: Int) {
        let windows = WindowCatalog.list().filter { $0.pid == pid }
        if let match = windows.first(where: { $0.title == title }) ?? (attemptsLeft == 0 && windows.count == 1 ? windows.first : nil) {
            Task { await pin(match) }
            return
        }
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.repinWhenReady(pid: pid, title: title, attemptsLeft: attemptsLeft - 1)
        }
    }

    private func toggleAllHidden() {
        allHidden.toggle()
        pips.forEach { $0.setUserHidden(allHidden) }
    }

    private func showPickerAtMouse() {
        let menu = NSMenu()
        windowItems().forEach(menu.addItem)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func pickWindow(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value,
              let window = WindowCatalog.list().first(where: { $0.id == id }) else { return }
        togglePin(window)
    }

    @objc private func pinFocusedFromMenu() { togglePinFocusedWindow() }

    @objc private func toggleHiddenFromMenu() { toggleAllHidden() }
    @objc private func unpinAll() { pips.forEach { $0.close() } }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("MacoPiP: launch at login failed: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    private func showPermissionAlert() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "MacoPiP needs Screen Recording permission"
        alert.informativeText = """
            MacoPiP mirrors windows with ScreenCaptureKit. Turn on MacoPiP in System Settings → \
            Privacy & Security → Screen & System Audio Recording, then quit and reopen MacoPiP.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        menu.removeAllItems()

        let pinItem = NSMenuItem(title: "Pin / Unpin Focused Window", action: #selector(pinFocusedFromMenu), keyEquivalent: "p")
        pinItem.keyEquivalentModifierMask = [.control, .option]
        pinItem.target = self
        menu.addItem(pinItem)

        let pickItem = NSMenuItem(title: "Pin Window", action: nil, keyEquivalent: "")
        let pickMenu = NSMenu()
        windowItems().forEach(pickMenu.addItem)
        pickItem.submenu = pickMenu
        menu.addItem(pickItem)

        let hideItem = NSMenuItem(title: allHidden ? "Show PiP" : "Hide PiP", action: #selector(toggleHiddenFromMenu), keyEquivalent: "h")
        hideItem.keyEquivalentModifierMask = [.control, .option]
        hideItem.target = self
        hideItem.isEnabled = !pips.isEmpty
        menu.addItem(hideItem)

        let unpinItem = NSMenuItem(title: "Unpin All", action: #selector(unpinAll), keyEquivalent: "")
        unpinItem.target = self
        unpinItem.isEnabled = !pips.isEmpty
        menu.addItem(unpinItem)

        menu.addItem(.separator())
        let help = NSMenuItem(title: "⌃⌥O pick window · ⌃⌥J jump to pinned app", action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MacoPiP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func windowItems() -> [NSMenuItem] {
        let windows = WindowCatalog.list()
        guard !windows.isEmpty else {
            let empty = NSMenuItem(title: "No windows found (check Screen Recording permission)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            return [empty]
        }
        let pinnedIDs = Set(pips.map(\.windowID))
        return windows.map { window in
            let item = NSMenuItem(title: window.label, action: #selector(pickWindow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: window.id)
            item.state = pinnedIDs.contains(window.id) ? .on : .off
            if let icon = NSRunningApplication(processIdentifier: window.pid)?.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            return item
        }
    }
}
