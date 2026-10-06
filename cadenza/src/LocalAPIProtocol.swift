import Foundation
import CryptoKit

// Local developer API, protocol layer. Pure and synchronous: no sockets, no pipeline.
// Version 1: control the Mac microphone and receive recognized text. It never writes into other
// applications, never returns provider credentials, and is bound to the loopback interface only.

enum LocalAPILimits {
    static let apiVersion = 1
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 64 * 1024
    static let maxWebSocketPayload = 64 * 1024
    static let defaultSeconds = 60
    static let maxSeconds = 120
    static let maxWait = 25
}

struct LocalAPIRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String] // lower-cased names
    var body: Data
}

struct LocalAPIResponse {
    var status: Int
    var body: Data
    var headers: [String: String] = [:]
    static func json(_ status: Int, _ object: Any) -> LocalAPIResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return LocalAPIResponse(status: status, body: data)
    }
    static func error(_ status: Int, _ code: String, _ message: String) -> LocalAPIResponse {
        json(status, ["error": ["code": code, "message": message]])
    }
}

enum LocalAPIHTTP {
    enum ParseResult {
        case needMore
        case request(LocalAPIRequest, consumed: Int)
        case reject(status: Int, code: String)
    }

    static func parse(_ buffer: Data) -> ParseResult {
        let marker = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: marker) else {
            return buffer.count > LocalAPILimits.maxHeaderBytes ? .reject(status: 431, code: "headers_too_large") : .needMore
        }
        guard end.lowerBound <= LocalAPILimits.maxHeaderBytes,
              let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .reject(status: 400, code: "bad_request")
        }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return .reject(status: 400, code: "bad_request") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .reject(status: 400, code: "bad_request") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, headers[name] == nil else { return .reject(status: 400, code: "bad_request") }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil else { return .reject(status: 400, code: "chunked_not_supported") }
        var length = 0
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else { return .reject(status: 400, code: "bad_request") }
            guard n <= LocalAPILimits.maxBodyBytes else { return .reject(status: 413, code: "payload_too_large") }
            length = n
        }
        let bodyStart = end.upperBound
        guard buffer.count - bodyStart >= length else { return .needMore }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        let target = first[1]
        var path = target, query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if let k = kv.first?.removingPercentEncoding { query[k] = (kv.count > 1 ? kv[1].removingPercentEncoding : "") ?? "" }
            }
        }
        guard path.hasPrefix("/"), !path.contains("..") else { return .reject(status: 400, code: "bad_request") }
        return .request(LocalAPIRequest(method: first[0].uppercased(), path: path, query: query, headers: headers, body: body),
                        consumed: bodyStart + length)
    }

    static func serialize(_ response: LocalAPIResponse) -> Data {
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                       409: "Conflict", 413: "Payload Too Large", 426: "Upgrade Required", 431: "Request Header Fields Too Large",
                       503: "Service Unavailable"]
        var head = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Status")\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\nContent-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n"
        for (k, v) in response.headers.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        return Data((head + "\r\n").utf8) + response.body
    }
}

enum LocalAPIWebSocket {
    static func acceptKey(for key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }
    static func handshake(_ request: LocalAPIRequest) -> Data? {
        guard let key = request.headers["sec-websocket-key"], Data(base64Encoded: key)?.count == 16 else { return nil }
        let text = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey(for: key))\r\n\r\n"
        return Data(text.utf8)
    }
    static func isUpgrade(_ request: LocalAPIRequest) -> Bool {
        request.headers["upgrade"]?.lowercased() == "websocket" && (request.headers["connection"]?.lowercased().contains("upgrade") ?? false)
    }

    enum Opcode: UInt8 { case text = 1, binary = 2, close = 8, ping = 9, pong = 10 }
    struct Frame { var opcode: Opcode; var payload: Data }
    enum DecodeResult { case needMore, frame(Frame, consumed: Int), invalid }

    /// Server-side frames are never masked; client frames must be masked, unfragmented and bounded.
    static func encode(_ opcode: Opcode, _ payload: Data) -> Data {
        var out = Data([0x80 | opcode.rawValue])
        if payload.count < 126 { out.append(UInt8(payload.count)) }
        else if payload.count <= 0xFFFF { out.append(126); out.append(UInt8(payload.count >> 8)); out.append(UInt8(payload.count & 0xFF)) }
        else { out.append(127); for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((payload.count >> shift) & 0xFF)) } }
        return out + payload
    }
    static func encodeText(_ text: String) -> Data { encode(.text, Data(text.utf8)) }

    static func decode(_ buffer: Data) -> DecodeResult {
        let b = [UInt8](buffer.prefix(14))
        guard b.count >= 2 else { return .needMore }
        guard b[0] & 0x80 != 0, b[0] & 0x70 == 0, let opcode = Opcode(rawValue: b[0] & 0x0F), b[1] & 0x80 != 0 else { return .invalid }
        var length = Int(b[1] & 0x7F), offset = 2
        if length == 126 { guard b.count >= 4 else { return .needMore }; length = Int(b[2]) << 8 | Int(b[3]); offset = 4 }
        else if length == 127 {
            guard b.count >= 10 else { return .needMore }
            guard b[2..<6].allSatisfy({ $0 == 0 }) else { return .invalid }
            length = (2..<10).reduce(0) { $0 << 8 | Int(b[$1]) }; offset = 10
        }
        guard length <= LocalAPILimits.maxWebSocketPayload else { return .invalid }
        if opcode.rawValue >= 8 && length > 125 { return .invalid }
        guard buffer.count >= offset + 4 + length else { return .needMore }
        let mask = [UInt8](buffer[buffer.startIndex + offset ..< buffer.startIndex + offset + 4])
        var payload = Data(buffer[buffer.startIndex + offset + 4 ..< buffer.startIndex + offset + 4 + length])
        for i in 0..<payload.count { payload[payload.startIndex + i] ^= mask[i % 4] }
        return .frame(Frame(opcode: opcode, payload: payload), consumed: offset + 4 + length)
    }
}

enum LocalAPIAuth {
    /// Constant-time comparison of the presented bearer token.
    static func verify(header: String?, token: String) -> Bool {
        guard !token.isEmpty, let header = header, header.count > 7, header.prefix(7).lowercased() == "bearer " else { return false }
        let presented = Array(header.dropFirst(7).trimmingCharacters(in: .whitespaces).utf8), expected = Array(token.utf8)
        var diff = presented.count ^ expected.count
        for i in 0..<expected.count { diff |= Int(i < presented.count ? presented[i] : 0) ^ Int(expected[i]) }
        return diff == 0
    }
    /// Browsers always send Origin on cross-site requests; non-browser clients do not. Host must be a loopback name
    /// with the listening port, which also defeats DNS rebinding.
    static func hostAllowed(_ host: String?, port: Int) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }
}

// MARK: - Backend and router

enum LocalAPISessionState: String { case recording, processing, completed, cancelled, failed }

struct LocalAPISessionInfo {
    var id: String
    var state: LocalAPISessionState
    var text: String?
    var errorCode: String?
    var detail: String?
    var elapsedMs: Int
    var json: [String: Any] {
        var o: [String: Any] = ["id": id, "state": state.rawValue, "elapsed_ms": elapsedMs]
        if let text = text { o["text"] = text }
        if let code = errorCode { o["error"] = ["code": code, "message": detail ?? ""] }
        return o
    }
}

struct LocalAPIFailure: Error { var status: Int; var code: String; var message: String }

protocol LocalAPIBackend: AnyObject {
    func capabilities() -> [String: Any]
    func start(maxSeconds: Int, owner: UUID?) -> Result<LocalAPISessionInfo, LocalAPIFailure>
    func stop(id: String) -> Result<LocalAPISessionInfo, LocalAPIFailure>
    func cancel(id: String) -> Result<LocalAPISessionInfo, LocalAPIFailure>
    func info(id: String) -> LocalAPISessionInfo?
    /// Invokes `done` once when the session is no longer recording or processing, or at the deadline.
    func wait(id: String, seconds: Int, done: @escaping (LocalAPISessionInfo?) -> Void)
}

enum LocalAPIRouter {
    enum Upgrade { case events, audio }
    enum Outcome { case respond(LocalAPIResponse), deferred, upgrade(Upgrade, LocalAPIPrincipal) }

    private struct OwnerOnly: LocalAPIAuthority {
        let token: String
        func principal(authorization: String?) -> LocalAPIPrincipal? { LocalAPIAuth.verify(header: authorization, token: token) ? .owner : nil }
    }

    /// Convenience for a single owner token (used by older callers and tests).
    static func handle(_ request: LocalAPIRequest, port: Int, token: String, backend: LocalAPIBackend,
                       reply: @escaping (LocalAPIResponse) -> Void) -> Outcome {
        handle(request, port: port, authority: OwnerOnly(token: token), backend: backend, reply: reply)
    }

    static func startOptions(_ body: Data) -> Result<Int, LocalAPIFailure> {
        guard !body.isEmpty else { return .success(LocalAPILimits.defaultSeconds) }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .failure(LocalAPIFailure(status: 400, code: "bad_request", message: "Body must be a JSON object."))
        }
        guard let raw = object["max_seconds"] else { return .success(LocalAPILimits.defaultSeconds) }
        guard let n = raw as? Int, (1...LocalAPILimits.maxSeconds).contains(n) else {
            return .failure(LocalAPIFailure(status: 400, code: "bad_request", message: "max_seconds must be an integer from 1 to \(LocalAPILimits.maxSeconds)."))
        }
        return .success(n)
    }

    /// Authentication happens before any routing, so unauthenticated callers learn nothing about the API surface.
    static func handle(_ request: LocalAPIRequest, port: Int, authority: LocalAPIAuthority, backend: LocalAPIBackend,
                       reply: @escaping (LocalAPIResponse) -> Void) -> Outcome {
        guard LocalAPIAuth.hostAllowed(request.headers["host"], port: port), request.headers["origin"] == nil else {
            return .respond(.error(403, "forbidden", "Request origin or host is not allowed."))
        }
        guard let principal = authority.principal(authorization: request.headers["authorization"]) else {
            var r = LocalAPIResponse.error(401, "unauthorized", "A valid bearer token is required.")
            r.headers["WWW-Authenticate"] = "Bearer"
            return .respond(r)
        }
        func denied(_ p: LocalAPIPermission) -> Outcome? {
            principal.allows(p) ? nil : .respond(.error(403, "permission_denied", "This token does not have the \(p.rawValue) permission."))
        }
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.first == "v1" else { return .respond(.error(404, "not_found", "Unknown path.")) }
        func method(_ allowed: String) -> LocalAPIResponse? {
            request.method == allowed ? nil : .error(405, "method_not_allowed", "Use \(allowed).")
        }
        func result(_ r: Result<LocalAPISessionInfo, LocalAPIFailure>) -> Outcome {
            switch r {
            case .success(let info): return .respond(.json(200, info.json))
            case .failure(let f): return .respond(.error(f.status, f.code, f.message))
            }
        }
        switch parts.dropFirst().joined(separator: "/") {
        case "capabilities":
            return .respond(method("GET") ?? .json(200, backend.capabilities()))
        case "ws", "audio":
            let kind: Upgrade = parts[1] == "audio" ? .audio : .events
            guard request.method == "GET" else { return .respond(.error(405, "method_not_allowed", "Use GET.")) }
            if let no = denied(kind == .audio ? .audio : .mic) { return no }
            return LocalAPIWebSocket.isUpgrade(request) && LocalAPIWebSocket.handshake(request) != nil
                ? .upgrade(kind, principal) : .respond(.error(426, "upgrade_required", "This endpoint requires a WebSocket upgrade."))
        case "sessions":
            if let bad = method("POST") { return .respond(bad) }
            if let no = denied(.mic) { return no }
            switch startOptions(request.body) {
            case .failure(let f): return .respond(.error(f.status, f.code, f.message))
            case .success(let seconds): return result(backend.start(maxSeconds: seconds, owner: nil))
            }
        default:
            guard parts.count >= 3, parts[1] == "sessions", parts.count <= 4 else { return .respond(.error(404, "not_found", "Unknown path.")) }
            if let no = denied(.mic) { return no }
            let id = parts[2]
            guard id.count == 32, id.allSatisfy({ $0.isHexDigit }) else { return .respond(.error(404, "not_found", "Unknown session.")) }
            if parts.count == 3 {
                if let bad = method("GET") { return .respond(bad) }
                guard let info = backend.info(id: id) else { return .respond(.error(404, "not_found", "Unknown session.")) }
                let wait = min(LocalAPILimits.maxWait, max(0, Int(request.query["wait"] ?? "0") ?? 0))
                guard wait > 0, info.state == .recording || info.state == .processing else { return .respond(.json(200, info.json)) }
                backend.wait(id: id, seconds: wait) { reply(.json(200, ($0 ?? info).json)) }
                return .deferred
            }
            switch parts[3] {
            case "stop": return method("POST").map { .respond($0) } ?? result(backend.stop(id: id))
            case "cancel": return method("POST").map { .respond($0) } ?? result(backend.cancel(id: id))
            default: return .respond(.error(404, "not_found", "Unknown path."))
            }
        }
    }
}
