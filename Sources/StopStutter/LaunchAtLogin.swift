import Foundation
import StopStutterCore

/// SMAppService.mainApp needs macOS 13. On macOS 12 a per-user LaunchAgent starts the app at login instead.
enum LaunchAtLogin {
    private static let label = ServiceIdentity.app + ".LaunchAtLogin"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func set(_ enabled: Bool) throws {
        let manager = FileManager.default
        if enabled {
            try manager.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } else if manager.fileExists(atPath: plistURL.path) {
            try manager.removeItem(at: plistURL)
        }
    }
}
