import Foundation

/// Serializes quit attempts and releases the app only after the VM has stopped.
/// Foundation-only so failures can be exercised with a temporary helper, without a real VM.
final class VMQuitGuard {
    enum Failure: Error, Equatable {
        case checkFailed, helperUnavailable, startFailed, suspendFailed(Int32)
        case stillRunning, timedOut, stillSuspending

        var message: String {
            switch self {
            case .checkFailed: return "Der Zustand der Windows-VM konnte nicht ermittelt werden."
            case .helperUnavailable: return "Das Werkzeug zum Anhalten der Windows-VM ist nicht verfügbar."
            case .startFailed: return "Das Werkzeug zum Anhalten der Windows-VM konnte nicht gestartet werden."
            case .suspendFailed(let code): return "Das Anhalten der Windows-VM ist fehlgeschlagen (Code \(code))."
            case .stillRunning: return "Nach dem Anhalten läuft weiterhin eine Windows-VM."
            case .timedOut: return "Das Anhalten der Windows-VM dauert länger als zwei Minuten. Der Vorgang läuft möglicherweise noch."
            case .stillSuspending: return "Der vorherige Versuch, die Windows-VM anzuhalten, läuft noch."
            }
        }
    }

    enum Decision: Equatable { case allow, cancel(Failure) }

    private let helperURL: URL
    private let timeout: TimeInterval
    private let isVMRunning: () throws -> Bool
    private var process: Process?
    private var completion: ((Decision) -> Void)?
    private var deadline: DispatchWorkItem?
    var isPreparing: Bool { completion != nil }

    init(helperURL: URL, timeout: TimeInterval = 120,
         isVMRunning: @escaping () throws -> Bool = VMQuitGuard.vmIsRunning) {
        self.helperURL = helperURL
        self.timeout = timeout
        self.isVMRunning = isVMRunning
    }

    /// All state and callbacks belong to the main queue. Even immediate results are delivered
    /// asynchronously, after applicationShouldTerminate has returned .terminateLater.
    func prepare(onSuspending: () -> Void, completion: @escaping (Decision) -> Void) {
        precondition(Thread.isMainThread)
        guard !isPreparing else { return }
        self.completion = completion
        // A timed-out helper may still be saving the VM. Never interrupt it or start a second one.
        guard process == nil else { finish(.cancel(.stillSuspending)); return }
        do {
            guard try isVMRunning() else { finish(.allow); return }
        } catch { finish(.cancel(.checkFailed)); return }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            finish(.cancel(.helperUnavailable)); return
        }

        let proc = Process()
        proc.executableURL = helperURL
        proc.arguments = ["suspend"]
        proc.environment = ProcessInfo.processInfo.environment.merging(
            ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]) { _, new in new }
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                self.process = nil
                // Timeout has already cancelled this quit. A late success must not quit the app.
                guard self.isPreparing else { return }
                guard p.terminationReason == .exit, p.terminationStatus == 0 else {
                    self.finish(.cancel(.suspendFailed(p.terminationStatus))); return
                }
                do {
                    self.finish(try self.isVMRunning() ? .cancel(.stillRunning) : .allow)
                } catch { self.finish(.cancel(.checkFailed)) }
            }
        }
        process = proc
        do { try proc.run() } catch {
            process = nil
            finish(.cancel(.startFailed)); return
        }
        onSuspending()
        let deadline = DispatchWorkItem { [weak self] in self?.finish(.cancel(.timedOut)) }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
    }

    private func finish(_ decision: Decision) {
        guard let callback = completion else { return }
        completion = nil
        deadline?.cancel()
        deadline = nil
        DispatchQueue.main.async { callback(decision) }
    }

    nonisolated private static func vmIsRunning() throws -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "vmware-vmx"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationReason == .exit else { throw Failure.checkFailed }
        switch p.terminationStatus {
        case 0: return true
        case 1: return false
        default: throw Failure.checkFailed
        }
    }
}
