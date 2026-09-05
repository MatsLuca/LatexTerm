import AppKit

struct LauncherAIResponse: Decodable {
    struct Hit: Decodable {
        var id: String
        var sessionID: String
        var agent: String
        var path: String
        var title: String
        var quote: String
        var source: String
    }
    struct Launch: Decodable {
        var path: String
        var label: String
        var agent: String
        var prompt: String
        var command: String
        var integration: String
    }
    var hits: [Hit]
    var launches: [Launch]
    var message: String
    var comparison: Bool?
}

/// One cancellable request to the private launcher backend. Queries travel on stdin, not in shell text.
final class LauncherAIRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    func start(payload: Data, completion: @escaping (Result<LauncherAIResponse, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", "exec projekte assist"]
            let input = Pipe(), output = Pipe()
            proc.standardInput = input; proc.standardOutput = output
            proc.standardError = FileHandle.nullDevice
            var result: Result<LauncherAIResponse, Error>
            do {
                lock.lock()
                if cancelled { lock.unlock(); return }
                do { try proc.run() } catch { lock.unlock(); throw error }
                process = proc; lock.unlock()
                let deadline = DispatchWorkItem { [weak self] in self?.cancel() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 80, execute: deadline)
                defer { deadline.cancel() }
                try input.fileHandleForWriting.write(contentsOf: payload)
                try input.fileHandleForWriting.close()
                let bytes = output.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else {
                    let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
                    throw LoaderError(message: object?["error"] as? String ?? "KI-Aufruf abgebrochen oder fehlgeschlagen. Die lokale Suche bleibt verfügbar.")
                }
                result = .success(try JSONDecoder().decode(LauncherAIResponse.self, from: bytes))
            } catch {
                if proc.isRunning { proc.terminate() }
                result = .failure(error)
            }
            lock.lock(); let stopped = cancelled; process = nil; lock.unlock()
            DispatchQueue.main.async {
                if stopped { completion(.failure(LoaderError(message: "KI-Aufruf beendet (Abbruch oder Zeitlimit)."))) }
                else { completion(result) }
            }
        }
    }
}
