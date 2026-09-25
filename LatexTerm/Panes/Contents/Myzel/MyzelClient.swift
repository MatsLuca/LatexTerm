import Foundation

/// HTTP zum Myzel-Server (PROTOKOLL §6.1): `Authorization: Bearer`, Fehlertexte kommen als Klartext, JSON-Körper
/// ohne fremde Schlüssel (der Server lehnt unbekannte ab). Eigene flüchtige URLSession ohne Cookies und Cache;
/// Weiterleitungen werden nicht verfolgt (das Token ginge sonst an einen anderen Host). Nur vom Main-Thread benutzen.
final class MyzelClient: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    struct Failure: Error, CustomStringConvertible {
        let status: Int
        let message: String
        var description: String { status == 0 ? message : "\(message) (\(status))" }
        /// Token ungültig oder nicht (mehr) an diesen Tailscale-Login gebunden.
        var isAuth: Bool { status == 401 }
    }

    let server: URL
    private let token: String
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60   // Leerlauf: der Strom schickt alle 25 s `: puls`
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    // Live-Strom
    private var streamTask: URLSessionDataTask?
    private var parser = MyzelSSEParser()
    private var onFrame: ((MyzelSSEParser.Frame) -> Void)?
    private var onEnd: ((Failure?) -> Void)?
    private var streamStatus = 0

    init(server: URL, token: String) {
        self.server = server
        self.token = token
    }

    func invalidate() {
        stopStream()
        session.invalidateAndCancel()
    }

    // MARK: Anfragen

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil,
                 body: Data? = nil, contentType: String? = nil) -> URLRequest {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.httpBody = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            request.httpBody = body
            request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Antwort-Körper bei 2xx, sonst `Failure` mit dem Klartext des Servers.
    func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure(status: 0, message: Self.describe(error))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(status: status, message: text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : text)
        }
        return data
    }

    func get<T: Decodable>(_ path: String, as type: T.Type, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(request("GET", path, query: query))
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw Failure(status: 0, message: "Antwort von \(path) nicht lesbar")
        }
    }

    func me() async throws -> MyzelMe { try await get("/ich", as: MyzelMe.self) }

    func data(_ path: String) async throws -> Data { try await send(request("GET", path)) }

    /// `POST` mit JSON-Körper; Antwort-Körper (oft leer bei 204).
    @discardableResult
    func post(_ path: String, json: [String: Any] = [:]) async throws -> Data {
        try await send(request("POST", path, json: json))
    }

    /// `POST /anhang?name=` mit den rohen Bytes; der Server prüft Typ und Inhalt (§7).
    func upload(name: String, mime: String, data: Data) async throws -> MyzelAttachment {
        let body = try await send(request("POST", "/anhang", query: [URLQueryItem(name: "name", value: name)],
                                          body: data, contentType: mime))
        do { return try JSONDecoder().decode(MyzelAttachment.self, from: body) } catch {
            throw Failure(status: 0, message: "Antwort auf den Upload nicht lesbar")
        }
    }

    // MARK: Live-Strom (SSE)

    /// `GET /ereignisse?nach=` mit `Accept: text/event-stream`: erst alles nach `after`, dann live. Rückrufe auf dem
    /// Main-Thread (Delegate-Queue), `onEnd` höchstens einmal; `stopStream` ruft ihn nicht.
    func startStream(after: String?, onFrame: @escaping (MyzelSSEParser.Frame) -> Void, onEnd: @escaping (Failure?) -> Void) {
        stopStream()
        var req = request("GET", "/ereignisse", query: after.map { [URLQueryItem(name: "nach", value: $0)] } ?? [])
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        parser = MyzelSSEParser()
        streamStatus = 0
        self.onFrame = onFrame
        self.onEnd = onEnd
        let task = session.dataTask(with: req)
        streamTask = task
        task.resume()
    }

    func stopStream() {
        let task = streamTask
        streamTask = nil
        onFrame = nil
        onEnd = nil
        task?.cancel()
    }

    /// Sekunden seit dem letzten Lebenszeichen des Stroms (Hänger-Erkennung).
    var streamSilence: TimeInterval { Date().timeIntervalSince(parser.lastActivity) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard dataTask === streamTask else { return completionHandler(.allow) }
        streamStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === streamTask else { return }
        if streamStatus != 200 {
            finishStream(Failure(status: streamStatus, message: String(decoding: data.prefix(300), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
            return
        }
        for frame in parser.feed(data) { onFrame?(frame) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === streamTask else { return }
        if let error, (error as NSError).code == NSURLErrorCancelled { return }
        finishStream(Failure(status: streamStatus == 200 ? 0 : streamStatus,
                             message: error.map(Self.describe) ?? "Verbindung beendet"))
    }

    private func finishStream(_ failure: Failure?) {
        let end = onEnd
        stopStream()
        end?(failure)
    }

    /// Keine Weiterleitungen: der Server leitet nie weiter, und das Token darf nicht mitwandern.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorNotConnectedToInternet: return "Kein Netz"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "Server nicht gefunden (Tailscale an?)"
        case NSURLErrorTimedOut: return "Zeitüberschreitung"
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost: return "Server nicht erreichbar"
        default: return ns.localizedDescription
        }
    }
}
