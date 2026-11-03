import AppKit
import StopStutterCore

enum HelperStatus: Equatable {
    case notInstalled, installed, outdated

    var isInstalled: Bool { self != .notInstalled }
}

/// macOS 12 has no SMAppService (macOS 13 and later). The helper is installed the classic way instead, with one
/// administrator prompt: copy the signed helper into /Library/PrivilegedHelperTools, install its launchd plist in
/// /Library/LaunchDaemons, and load it. The XPC trust rules do not change: each side validates the other's signature.
@MainActor
final class HelperInstaller {
    static let toolPath = "/Library/PrivilegedHelperTools/\(ServiceIdentity.helper)"
    static let daemonPath = "/Library/LaunchDaemons/\(ServiceIdentity.helper).plist"

    private struct FileStamp: Equatable {
        let size: UInt64
        let modified: Date

        init?(path: String) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let modified = attributes[.modificationDate] as? Date
            else { return nil }
            self.size = size
            self.modified = modified
        }
    }

    /// Comparing the two binaries byte for byte on every two-second refresh would be wasteful; remember the result
    /// until either file changes.
    private var comparison: (installed: FileStamp, bundled: FileStamp, identical: Bool)?

    private var bundledHelper: String { Bundle.main.bundlePath + "/Contents/MacOS/StopStutterHelper" }
    private var bundledDaemon: String { Bundle.main.bundlePath + "/Contents/Resources/" + ServiceIdentity.daemonPlist }

    var status: HelperStatus {
        let manager = FileManager.default
        guard let installed = FileStamp(path: Self.toolPath), manager.fileExists(atPath: Self.daemonPath) else {
            return .notInstalled
        }
        guard let bundled = FileStamp(path: bundledHelper) else { return .installed }
        if let comparison, comparison.installed == installed, comparison.bundled == bundled {
            return comparison.identical ? .installed : .outdated
        }
        let identical = manager.contentsEqual(atPath: Self.toolPath, andPath: bundledHelper)
        comparison = (installed, bundled, identical)
        return identical ? .installed : .outdated
    }

    /// Installs or replaces the helper. Shows the system administrator prompt.
    func install() throws {
        let resolved = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix("/Applications/") else {
            throw ControlError.connectionFailed("Move Stop Stutter to Applications, then open it from there to enable the helper.")
        }
        let label = ServiceIdentity.helper
        let tool = Self.shellQuoted(Self.toolPath)
        let daemon = Self.shellQuoted(Self.daemonPath)
        let script = [
            "set -e",
            "/bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true",
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/bin/cp \(Self.shellQuoted(bundledHelper)) \(tool)",
            "/usr/sbin/chown root:wheel \(tool)",
            "/bin/chmod 755 \(tool)",
            "/usr/bin/xattr -c \(tool) || true",
            "/bin/cp \(Self.shellQuoted(bundledDaemon)) \(daemon)",
            "/usr/sbin/chown root:wheel \(daemon)",
            "/bin/chmod 644 \(daemon)",
            "/usr/bin/xattr -c \(daemon) || true",
            "/bin/launchctl bootstrap system \(daemon)"
        ].joined(separator: "\n")
        try Self.runAsAdministrator(script)
        comparison = nil
    }

    /// Stops the helper (it restores AWDL on SIGTERM) and deletes its files. Shows the administrator prompt.
    func uninstall() throws {
        let script = [
            "/bin/launchctl bootout system/\(ServiceIdentity.helper) >/dev/null 2>&1 || true",
            "/bin/rm -f \(Self.shellQuoted(Self.daemonPath)) \(Self.shellQuoted(Self.toolPath))"
        ].joined(separator: "\n")
        try Self.runAsAdministrator(script)
        comparison = nil
    }

    /// `do shell script … with administrator privileges` shows the standard macOS password prompt for this app.
    private static func runAsAdministrator(_ script: String) throws {
        let source = "do shell script \"\(appleScriptEscaped(script))\" with administrator privileges"
        guard let appleScript = NSAppleScript(source: source) else {
            throw ControlError.connectionFailed("Could not prepare the helper setup.")
        }
        var errorInfo: NSDictionary?
        _ = appleScript.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return }
        if (errorInfo["NSAppleScriptErrorNumber"] as? Int) == -128 {
            throw ControlError.connectionFailed("Helper setup was cancelled.")
        }
        let message = (errorInfo["NSAppleScriptErrorMessage"] as? String) ?? "unknown error"
        throw ControlError.connectionFailed("Helper setup failed: \(message)")
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
