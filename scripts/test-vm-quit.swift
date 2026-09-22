import Foundation

@main
struct VMQuitTests {
    static func wait(until done: () -> Bool, seconds: TimeInterval = 5) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(done(), "Timed out waiting for test callback")
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("latexterm vm test \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func helper(_ name: String, _ body: String, executable: Bool = true) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: url.path)
            return url
        }
        let missing = directory.appendingPathComponent("missing")
        let success = try helper("success", "#!/bin/sh\n[ \"$1\" = suspend ] || exit 9\nexit 0\n")
        let failed = try helper("failed", "#!/bin/sh\nexit 7\n")
        let invalid = try helper("invalid", "#!/no-such-interpreter\n")
        let nonExecutable = try helper("not-executable", "#!/bin/sh\nexit 0\n", executable: false)
        let slow = try helper("slow", "#!/bin/sh\nexec /bin/sleep 0.4\n")
        let signalled = try helper("signalled", "#!/bin/sh\nkill -TERM $$\n")
        var cases = 0

        func expect(_ guarder: VMQuitGuard, _ expected: VMQuitGuard.Decision, suspends: Bool = false) {
            var decisions: [VMQuitGuard.Decision] = []
            var starts = 0
            guarder.prepare(onSuspending: { starts += 1 }) { decisions.append($0) }
            precondition(decisions.isEmpty, "Reply must follow the delegate's terminateLater return")
            wait { !decisions.isEmpty }
            precondition(decisions == [expected], "Expected \(expected), got \(decisions)")
            precondition(starts == (suspends ? 1 : 0))
            precondition(!guarder.isPreparing)
            cases += 1
        }

        expect(VMQuitGuard(helperURL: missing, isVMRunning: { false }), .allow)
        expect(VMQuitGuard(helperURL: missing, isVMRunning: { true }), .cancel(.helperUnavailable))
        expect(VMQuitGuard(helperURL: nonExecutable, isVMRunning: { true }), .cancel(.helperUnavailable))
        expect(VMQuitGuard(helperURL: success, isVMRunning: { throw VMQuitGuard.Failure.checkFailed }), .cancel(.checkFailed))
        expect(VMQuitGuard(helperURL: invalid, isVMRunning: { true }), .cancel(.startFailed))
        expect(VMQuitGuard(helperURL: failed, isVMRunning: { true }), .cancel(.suspendFailed(7)), suspends: true)
        expect(VMQuitGuard(helperURL: signalled, isVMRunning: { true }), .cancel(.suspendFailed(15)), suspends: true)
        expect(VMQuitGuard(helperURL: success, isVMRunning: { true }), .cancel(.stillRunning), suspends: true)
        var checks = 0
        expect(VMQuitGuard(helperURL: success, isVMRunning: {
            checks += 1
            if checks == 2 { throw VMQuitGuard.Failure.checkFailed }
            return true
        }), .cancel(.checkFailed), suspends: true)
        checks = 0
        expect(VMQuitGuard(helperURL: success, isVMRunning: {
            checks += 1; return checks == 1
        }), .allow, suspends: true)

        // One pending quit, no duplicate helper, no late success after timeout, then a clean retry.
        var running = true
        let guarder = VMQuitGuard(helperURL: slow, timeout: 0.05, isVMRunning: { running })
        var decisions: [VMQuitGuard.Decision] = []
        var starts = 0
        guarder.prepare(onSuspending: { starts += 1 }) { decisions.append($0) }
        guarder.prepare(onSuspending: { preconditionFailure("Duplicate helper") }) { _ in
            preconditionFailure("Duplicate quit callback")
        }
        wait { decisions.count == 1 }
        precondition(decisions == [.cancel(.timedOut)] && starts == 1)
        cases += 1
        expect(guarder, .cancel(.stillSuspending))
        running = false
        // Let the real temporary helper finish; the app must remain open after its late exit 0.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        precondition(decisions == [.cancel(.timedOut)])
        cases += 1
        expect(guarder, .allow)

        // A failed suspension can be retried on the same guard after the helper is repaired.
        var retryChecks = 0
        let retry = VMQuitGuard(helperURL: failed, isVMRunning: {
            retryChecks += 1; return retryChecks < 3
        })
        expect(retry, .cancel(.suspendFailed(7)), suspends: true)
        _ = try helper("failed", "#!/bin/sh\nexit 0\n")
        expect(retry, .allow, suspends: true)
        print("\(cases) VM quit cases passed (temporary helpers only)")
    }
}
