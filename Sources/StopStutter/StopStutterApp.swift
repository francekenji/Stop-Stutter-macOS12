import AppKit
import Combine
import SwiftUI
import UserNotifications

@main
struct StopStutterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // `Window` and `MenuBarExtra` need macOS 13, so the main window and the menu bar item are plain AppKit
    // (see AppDelegate). SwiftUI only supplies the lifecycle and the default app menu.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("About Stop Stutter") {
                        NSApp.orderFrontStandardAboutPanel(options: [
                            .credits: NSAttributedString(string: "Smoother game streaming on Mac.\nOpen source · MIT License\ngithub.com/burakgon/stop-stutter")
                        ])
                    }
                }
                CommandGroup(replacing: .appSettings) {}
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let model = AppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        setUpStatusItem()
        showMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await model.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func showMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: MainView(model: model)))
            window.title = "Stop Stutter"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 880, height: 680)
            window.setContentSize(NSSize(width: 980, height: 780))
            window.center()
            window.setFrameAutosaveName("StopStutterMainWindow")
            mainWindow = window
        }
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuContent(model: model) { [weak self] in
            self?.showMainWindow()
        })
        // objectWillChange fires before the change lands, so read the new state on the next main-actor turn.
        model.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.updateStatusIcon() } }
            .store(in: &cancellables)
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let protected = model.protected
        let description = protected ? "Stop Stutter: boost on" : "Stop Stutter"
        let image = NSImage(systemSymbolName: protected ? "waveform.path" : "waveform.path.ecg",
                            accessibilityDescription: description)
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = description
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
