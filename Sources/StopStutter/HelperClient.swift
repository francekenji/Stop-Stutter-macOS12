import Foundation
import StopStutterCore

@MainActor
final class HelperClient {
    private var connection: NSXPCConnection?
    /// macOS 12 cannot make the connection validate the helper's signature itself (setCodeSigningRequirement
    /// needs macOS 13), so the first reply on each connection is checked here before it is trusted.
    private var peerVerified = false
    private var requirement = ""

    private static var needsManualPeerCheck: Bool {
        if #available(macOS 13.0, *) { return false }
        return true
    }

    func update(suppress: Bool) async throws -> HelperSnapshot {
        let connection = try connect()
        let snapshot: HelperSnapshot = try await withCheckedThrowingContinuation { continuation in
            let reply = ReplyOnce(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { reply.finish(.failure(HelperTimeout())) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                reply.finish(.failure(error))
            }) as? AWDLHelperProtocol else {
                reply.finish(.failure(ControlError.connectionFailed("Could not connect to the AWDL helper.")))
                return
            }
            proxy.updateLease(suppress) { data in
                do {
                    let snapshot = try JSONDecoder().decode(HelperSnapshot.self, from: data)
                    guard snapshot.protocolVersion == ServiceIdentity.protocolVersion else {
                        throw ControlError.connectionFailed("The helper needs updating. Use Update Helper in Settings.")
                    }
                    reply.finish(.success(snapshot))
                } catch { reply.finish(.failure(error)) }
            }
        }
        if Self.needsManualPeerCheck && !peerVerified {
            guard PeerTrust.verify(connection, against: requirement) else {
                throw ControlError.connectionFailed("The process answering as the AWDL helper is not the signed Stop Stutter helper. Use Update Helper in Settings.")
            }
            peerVerified = true
        }
        return snapshot
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
        peerVerified = false
    }

    private func connect() throws -> NSXPCConnection {
        if let connection { return connection }
        let requirement = try PeerTrust.requirement(for: ServiceIdentity.helper)
        let connection = NSXPCConnection(machServiceName: ServiceIdentity.helper, options: .privileged)
        if #available(macOS 13.0, *) { connection.setCodeSigningRequirement(requirement) }
        connection.remoteObjectInterface = NSXPCInterface(with: AWDLHelperProtocol.self)
        connection.resume()
        self.connection = connection
        self.requirement = requirement
        peerVerified = false
        return connection
    }
}

/// A slow reply is not a broken connection. Keeping the connection keeps the helper's lease for this app.
struct HelperTimeout: LocalizedError {
    var errorDescription: String? { "The helper did not respond. Use Update Helper or Enable Helper in Settings." }
}

/// XPC can race a timeout, invalidation and reply. Resume the continuation exactly once.
private final class ReplyOnce {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HelperSnapshot, Error>?

    init(_ continuation: CheckedContinuation<HelperSnapshot, Error>) { self.continuation = continuation }

    func finish(_ result: Result<HelperSnapshot, Error>) {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.resume(with: result)
    }
}
