import Darwin
import Foundation
import os
import StopStutterCore

private let log = Logger(subsystem: ServiceIdentity.helper, category: "Service")

final class HelperService: NSObject, NSXPCListenerDelegate {
    let queue = DispatchQueue(label: ServiceIdentity.helper + ".enforcement", qos: .userInitiated)
    private let engine: EnforcementEngine
    private var monitor: InterfaceMonitor?
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private let updates = UpdateDetector()
    private var loggedRevivals = 0
    private var loggedExpiries = 0
    private var loggedError: String?
    private var loggedIdle: Bool
    /// Requirement the connecting app must satisfy. macOS 12 cannot enforce it inside the listener.
    private let appRequirement: String

    init(engine: EnforcementEngine, appRequirement: String) {
        self.engine = engine
        self.appRequirement = appRequirement
        loggedIdle = engine.isIdle
        super.init()
        queue.sync { perform { $0.tick(now: MonotonicTime.now) } }
        do {
            monitor = try InterfaceMonitor(queue: queue) { [weak self] in
                self?.perform { $0.tick(now: MonotonicTime.now) }
            }
        } catch {
            log.error("Interface events unavailable; using the one-second check only: \(error.localizedDescription, privacy: .public)")
        }
        // The safety net for anything the event path misses, and the clock that expires leases.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(25))
        timer.setEventHandler { [weak self] in
            self?.perform { $0.tick(now: MonotonicTime.now) }
            self?.restartIfUpdated()
        }
        timer.resume()
        self.timer = timer
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [weak self] in
                self?.perform { $0.shutdown(now: MonotonicTime.now) }
                exit(0)
            }
            source.resume()
            signals.append(source)
        }
    }

    /// Every engine call runs on `queue` through here, so the session timeline reaches the unified log.
    func perform<T>(_ body: (EnforcementEngine) -> T) -> T {
        let result = body(engine)
        if engine.isIdle != loggedIdle {
            log.notice("\(self.engine.isIdle ? "Boost ended; AWDL restored." : "Boost started; holding AWDL down.", privacy: .public)")
            loggedIdle = engine.isIdle
        }
        if engine.revivals > loggedRevivals {
            log.notice("macOS turned AWDL back on; turned it off again (\(self.engine.revivals, privacy: .public) this session).")
        }
        loggedRevivals = engine.revivals
        if engine.expiredLeases > loggedExpiries {
            log.error("A Boost lease expired without renewal; the app stopped sending heartbeats.")
            loggedExpiries = engine.expiredLeases
        }
        if let error = engine.lastError, error != loggedError {
            log.error("\(error, privacy: .public)")
        }
        loggedError = engine.lastError
        return result
    }

    /// Once an update replaces the executable, this process fails every client's code-signature check and can no
    /// longer serve a session. Restore AWDL, then exit nonzero so launchd starts the new build.
    private func restartIfUpdated() {
        guard updates?.updateInstalled() == true else { return }
        log.notice("A new helper was installed; restarting to load it.")
        perform { $0.shutdown(now: MonotonicTime.now) }
        exit(EX_TEMPFAIL)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        if #available(macOS 13.0, *) {
            // The listener already validated the client's signature and exact app identifier
            // (setConnectionCodeSigningRequirement below).
        } else if !PeerTrust.verify(connection, against: appRequirement) {
            // macOS 12: check the live connection's code signature ourselves.
            log.error("Rejected a client that is not the signed Stop Stutter app.")
            return false
        }
        let session = HelperSession(service: self)
        connection.exportedInterface = NSXPCInterface(with: AWDLHelperProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { [weak self] in
            self?.queue.async { self?.perform { $0.disconnect(session.id, now: MonotonicTime.now) } }
        }
        connection.interruptionHandler = connection.invalidationHandler
        connection.resume()
        return true
    }
}

final class HelperSession: NSObject, AWDLHelperProtocol {
    let id = UUID()
    private let service: HelperService
    init(service: HelperService) { self.service = service }

    func updateLease(_ suppress: Bool, withReply reply: @escaping (Data) -> Void) {
        service.queue.async { [self] in
            let snapshot = service.perform { $0.updateLease(id, suppress: suppress, now: MonotonicTime.now) }
            reply((try? JSONEncoder().encode(snapshot)) ?? Data())
        }
    }
}

do {
    guard geteuid() == 0 else {
        throw ControlError.connectionFailed("The helper must be started by launchd.")
    }
    let requirement = try PeerTrust.requirement(for: ServiceIdentity.app)
    let engine = try EnforcementEngine(driver: SystemAWDLDriver(), journal: RecoveryJournal())
    let service = HelperService(engine: engine, appRequirement: requirement)
    let listener = NSXPCListener(machServiceName: ServiceIdentity.helper)
    if #available(macOS 13.0, *) { listener.setConnectionCodeSigningRequirement(requirement) }
    listener.delegate = service
    listener.resume()
    log.notice("Helper revision \(ServiceIdentity.helperRevision, privacy: .public) ready; AWDL revivals are corrected on interface events.")
    withExtendedLifetime((service, listener)) { RunLoop.current.run() }
} catch {
    log.error("Helper could not start: \(error.localizedDescription, privacy: .public)")
    exit(1)
}
