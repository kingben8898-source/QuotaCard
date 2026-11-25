import Foundation
import Network
import Security

public struct LocalHTTPResponse: Sendable {
    public let statusCode: Int
    public let reasonPhrase: String
    public let body: Data

    public init(statusCode: Int, reasonPhrase: String, body: Data) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.body = body
    }

    public func serialized() -> Data {
        var header = "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n"
        header += "Content-Type: application/json; charset=utf-8\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }
}

public final class LocalIngestServer: @unchecked Sendable {
    public let store: StateStore
    public let requestedPort: UInt16
    public let tokenFileURL: URL
    public let authToken: String

    private let stateLock = NSLock()
    private let queue = DispatchQueue(label: "com.quotacard.local-ingest-server")
    private var _listener: NWListener?
    private var _listeningPort: UInt16?
    private var _onUpdateApplied: (@Sendable () -> Void)?
    private var _onError: (@Sendable (String) -> Void)?

    public var listeningPort: UInt16? {
        stateLock.withLock { _listeningPort }
    }

    public var onUpdateApplied: (@Sendable () -> Void)? {
        get { stateLock.withLock { _onUpdateApplied } }
        set { stateLock.withLock { _onUpdateApplied = newValue } }
    }

    public var onError: (@Sendable (String) -> Void)? {
        get { stateLock.withLock { _onError } }
        set { stateLock.withLock { _onError = newValue } }
    }

    public init(
        store: StateStore,
        port: UInt16 = 18421,
        tokenFileURL: URL? = nil
    ) {
        self.store = store
        self.requestedPort = port
        let resolvedTokenURL = tokenFileURL ?? store.baseDirectory.appendingPathComponent("auth-token")
        self.tokenFileURL = resolvedTokenURL
        self.authToken = LocalIngestServer.loadOrCreateToken(at: resolvedTokenURL)
    }

    public func start() throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: requestedPort) ?? .any
        )

        let newListener = try NWListener(using: params)
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let boundPort = newListener.port?.rawValue
                self.stateLock.withLock { self._listeningPort = boundPort }
            case .failed(let error):
                self.stateLock.withLock { self._listeningPort = nil }
                self.onError?("本机 HTTP 监听失败（127.0.0.1:\(self.requestedPort)）：\(error.localizedDescription)")
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        newListener.start(queue: queue)
        stateLock.withLock { _listener = newListener }
    }

    public func stop() {
        let toCancel: NWListener? = stateLock.withLock {
            let current = _listener
            _listener = nil
            _listeningPort = nil
            return current
        }
        toCancel?.cancel()
    }

    public func handleRawHTTPRequest(_ raw: Data, now: Date = Date()) -> LocalHTTPResponse {
        guard let separatorRange = raw.range(of: Data("\r\n\r\n".utf8)) else {
            return jsonResponse(400, "Bad Request", #"{"error":"malformed_http"}"#)
        }
        let headerData = raw.subdata(in: raw.startIndex..<separatorRange.lowerBound)
        let bodyData = raw.subdata(in: separatorRange.upperBound..<raw.endIndex)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return jsonResponse(400, "Bad Request", #"{"error":"invalid_headers"}"#)
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return jsonResponse(400, "Bad Request", #"{"error":"missing_request_line"}"#)
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return jsonResponse(400, "Bad Request", #"{"error":"invalid_request_line"}"#)
        }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }

        if method == "GET" && path == "/v1/health" {
            return jsonResponse(200, "OK", #"{"status":"ok"}"#)
        }

        if method == "POST", path.hasPrefix("/v1/providers/") {
            let providerId = String(path.dropFirst("/v1/providers/".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            guard !providerId.isEmpty,
                  providerId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            else {
                return jsonResponse(400, "Bad Request", #"{"error":"invalid_provider_id"}"#)
            }

            guard let authHeader = headers["authorization"],
                  authHeader.hasPrefix("Bearer ")
            else {
                return jsonResponse(401, "Unauthorized", #"{"error":"missing_token"}"#)
            }
            let providedToken = String(authHeader.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
            guard constantTimeEquals(providedToken, authToken) else {
                return jsonResponse(401, "Unauthorized", #"{"error":"invalid_token"}"#)
            }

            guard let update = PayloadParser.parse(providerId: providerId, data: bodyData, now: now) else {
                return jsonResponse(400, "Bad Request", #"{"error":"invalid_payload"}"#)
            }
            do {
                _ = try store.applyUpdate(update)
                onUpdateApplied?()
                return jsonResponse(200, "OK", #"{"status":"updated"}"#)
            } catch {
                return jsonResponse(500, "Internal Server Error", #"{"error":"persist_failed"}"#)
            }
        }

        return jsonResponse(404, "Not Found", #"{"error":"not_found"}"#)
    }

    // MARK: - Networking

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveBuffer(connection: connection, accumulated: Data())
    }

    private func receiveBuffer(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var next = accumulated
            if let data {
                next.append(data)
            }

            if next.count > 1_048_576 {
                self.sendAndClose(connection: connection, response: self.jsonResponse(413, "Payload Too Large", #"{"error":"payload_too_large"}"#))
                return
            }

            if self.isHTTPRequestComplete(next) || isComplete {
                let response = self.handleRawHTTPRequest(next)
                self.sendAndClose(connection: connection, response: response)
            } else {
                self.receiveBuffer(connection: connection, accumulated: next)
            }
        }
    }

    private func isHTTPRequestComplete(_ data: Data) -> Bool {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let headerData = data.subdata(in: data.startIndex..<sep.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return true }
        var contentLength = 0
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            if line.lowercased().hasPrefix("content-length:") {
                let raw = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(raw) ?? 0
            }
        }
        let currentBodyLength = data.count - sep.upperBound
        return currentBodyLength >= contentLength
    }

    private func sendAndClose(connection: NWConnection, response: LocalHTTPResponse) {
        connection.send(
            content: response.serialized(),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    private func jsonResponse(_ code: Int, _ reason: String, _ json: String) -> LocalHTTPResponse {
        LocalHTTPResponse(statusCode: code, reasonPhrase: reason, body: Data(json.utf8))
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(aBytes, bBytes) {
            diff |= x ^ y
        }
        return diff == 0
    }

    private static func loadOrCreateToken(at url: URL) -> String {
        if let existing = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count >= 32 {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token: String
        if status == errSecSuccess {
            token = bytes.map { String(format: "%02x", $0) }.joined()
        } else {
            token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data((token + "\n").utf8),
            attributes: [.posixPermissions: 0o600]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }
}
